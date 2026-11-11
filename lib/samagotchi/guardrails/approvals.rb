# frozen_string_literal: true

require "digest"
require "json"
require "fileutils"
require "time"
require_relative "../atomic_file"
require_relative "../log"
require_relative "../state_format"
require_relative "approval"

module Samagotchi
  module Guardrails
    # The user's stored approvals: one JSON file under the state dir,
    # written aside and renamed under an exclusive flock (several chi
    # processes share it). An entry relaxes an ask, never a deny:
    #   session — this exact call (tool + normalized command / paths) in
    #             this session; a command's in its place too (the
    #             worktree or folder it ran in, and a digest of its env:),
    #             since the same text acts on whatever they point at;
    #   repo    — this exact call in this repo (the cwd outside a repo);
    #   rule    — anything this rule (from this source) asks about here.
    # "This repo" is the repository (repo: its common git dir), so an
    # approval holds in every worktree of it; repo_root, the worktree it
    # was given in, is kept for showing, and an entry from before repo:
    # still matches that exact folder.
    # "once" is never stored. A file that doesn't parse is moved aside to
    # approvals.json.corrupt-<UTC time>[-N], with a warning, and the store
    # starts empty: it only means more asks, and nothing is overwritten.
    #
    # The file is a versioned store, {"version", "approvals": [...]}
    # (FORMAT); a write keeps its version and the keys this chi doesn't
    # know. A bare list of entries (what 0.166 and before wrote) is not
    # a versioned store: it is set aside like an unreadable file.
    class Approvals
      FILE = "approvals.json"
      COLLECTION = "approvals"
      FORMAT = StateFormat.new(version: 1, members: [StateFormat.required(:scope), StateFormat.extra(:extra, in_version: 1)])
      STORED_SCOPES = %w[session repo rule].freeze
      # Rules a stored answer allows only for its session: their asks offer
      # once/session, and a repo entry for the same call (from another
      # rule) would hold in every worktree, for every child.
      SESSION_ONLY_RULES = %w[child-boundary].freeze

      # @param sessions_dir [String] Session's state dir
      #   ($XDG_STATE_HOME/samagotchi/sessions): the store sits beside it,
      #   not among the sessions
      def self.dir_for(sessions_dir) = File.join(File.dirname(sessions_dir), "guardrails")

      attr_reader :path

      def initialize(dir:, warn: ->(msg) { Log.warn(:guardrails, "approvals_unreadable", echo: msg) })
        @dir = dir
        @path = File.join(dir, FILE)
        @warn = warn
        @warned = false
      end

      # @return [Array<Hash>] the entries (string keys), oldest first
      def entries
        read.first
      end

      # @param verdict [Verdict] an ask with its targets and context
      # @return [Hash, nil] the first entry that allows it
      def match(verdict)
        self.class.find_in(read.first, verdict)
      end

      # Store the verdict's allowed scope (not "once").
      # @return [Hash, nil] the entry
      def add(verdict, scope)
        entry = self.class.entry_for(verdict, scope) or return nil

        update { |list| list << entry unless list.any? { |e| e.except("created_at") == entry.except("created_at") } }
        entry
      end

      # @param list [Array<Hash>] entries
      # @return [Hash, nil] the first of +list+ that allows +verdict+
      def self.find_in(list, verdict)
        key = key_for(verdict)
        place = place_for(verdict)
        repo = verdict.targets&.repo
        here = ->(e) { e["repo"] ? e["repo"] == repo : e["repo_root"] == place }
        session_id = verdict.context&.session_id
        session_only = SESSION_ONLY_RULES.include?(verdict.rule.to_s)
        command_place = session_place(verdict)
        list.find do |e|
          next false if session_only && e["scope"] != "session"

          case e["scope"]
          when "session"
            session_id && e["session_id"] == session_id && e["key"] == key &&
              (command_place.nil? || e.slice("repo_root", "env") == command_place)
          when "repo" then here.call(e) && e["key"] == key
          when "rule"
            # One rule's grant can't answer for a second rule's ask on the call.
            !verdict.second_rule_ask? && verdict.rule && e["rule"] == verdict.rule && e["source"] == verdict.source && here.call(e)
          end
        end
      end

      # @return [Hash, nil] the entry that stores +scope+ for +verdict+; nil for "once"
      def self.entry_for(verdict, scope)
        return nil unless STORED_SCOPES.include?(scope)

        entry = { "scope" => scope, "tool" => verdict.targets&.tool || verdict.call[:name].to_s,
                  "acts_as" => verdict.targets&.acts_as, "rule" => verdict.rule, "source" => verdict.source, "created_at" => Time.now.utc.iso8601 }
        case scope
        when "session"
          entry.merge!("session_id" => verdict.context&.session_id, "key" => key_for(verdict))
          entry.merge!(session_place(verdict) || {})
        when "repo"
          entry.merge!("repo_root" => place_for(verdict), "repo" => verdict.targets&.repo, "key" => key_for(verdict))
        when "rule" then entry.merge!("repo_root" => place_for(verdict), "repo" => verdict.targets&.repo)
        end
        entry.compact
      end

      # Remove entry +index+ (0-based, as #entries lists them).
      # @return [Hash, nil] the removed entry
      def revoke(index)
        removed = nil
        update { |list| removed = list.delete_at(index) if index >= 0 && index < list.size }
        removed
      end

      # tool + the normalized command, or the sorted paths; for a plugin
      # tool with neither (an MCP tool), its arguments, so "this call" is
      # this call. A call that acts as another tool keys as
      # `call_tool>mcp_github_x`: the real name stays in, so it never reuses
      # that tool's own approvals (nor they its).
      def self.key_for(verdict)
        t = verdict.targets
        return "#{verdict.call[:name]}:" unless t

        tool = t.acts_as ? "#{t.tool}>#{t.acts_as}" : t.tool
        return "#{tool}:#{t.command.to_s.strip.gsub(/\s+/, " ")}" if t.command
        return "#{tool}:#{Approval.args_text(t.args)}" if t.paths.empty?

        "#{tool}:#{t.paths.sort.join("\n")}"
      end

      def self.place_for(verdict)
        t = verdict.targets
        t&.repo_root || t&.cwd || verdict.context&.cwd
      end

      # Where a session entry of a command holds: the call's worktree root
      # (or folder: #place_for; never the common git dir, which every
      # worktree shares) and, when it sets one, a sha256 of its env: (never
      # the env: it may hold a secret). nil for a call with no command:
      # its paths are its place. An entry without them (stored before) no
      # longer matches: one more ask.
      # @return [Hash, nil]
      def self.session_place(verdict)
        t = verdict.targets
        return nil unless t&.command

        env = t.env.to_h
        digest = env.empty? ? nil : Digest::SHA256.hexdigest(JSON.generate(env.map { |k, v| [k.to_s, v.to_s] }.sort))
        { "repo_root" => place_for(verdict), "env" => digest }.compact
      end

      private

      # @param locked [Boolean] the caller holds the store's lock
      # @return [Array(Array<Hash>, StateFormat::Document)] the entries and,
      #   its document (nil when there is no file)
      def read(locked: false)
        return [[], nil] unless File.exist?(@path)

        parse(File.read(@path))
      rescue JSON::ParserError, SystemCallError => e
        aside = begin
          locked ? set_aside : with_lock { set_aside }
        rescue SystemCallError
          nil
        end
        return read(locked: locked) if aside == :readable

        unless @warned
          @warned = true
          where = aside ? "moved it to #{aside}" : "left it in place"
          @warn.call("[samagotchi:guardrails] #{@path} is unreadable (#{e.message}); #{where}, no stored approvals apply")
        end
        [[], nil]
      end

      # @return [Array(Array<Hash>, StateFormat::Document)] as #read's
      def parse(text)
        data = JSON.parse(text)
        case data
        when Hash
          raise JSON::ParserError, "#{COLLECTION} is not a list" unless data.fetch(COLLECTION, []).is_a?(Array)

          document = FORMAT.read(data, collection: COLLECTION)
          # An entry it can't read (no scope) is kept as it is: it matches
          # nothing, and a write keeps it for the chi that wrote it.
          [document.entries.map(&:raw).select { |e| e.is_a?(Hash) }, document]
        else raise JSON::ParserError, "not a versioned store"
        end
      end

      def write(document)
        AtomicFile.write(@path, JSON.pretty_generate(FORMAT.write(document, collection: COLLECTION, updated_at: nil)))
      end

      # Under the lock: rename the file aside if it is still unreadable.
      # @return [String, :readable] where it went; :readable when another
      #   process replaced or removed it meanwhile
      def set_aside
        return :readable unless File.exist?(@path)

        begin
          parse(File.read(@path))
          return :readable
        rescue JSON::ParserError, SystemCallError
          nil
        end
        base = "#{@path}.corrupt-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
        # A second one within the same second must not replace the first
        # (we hold the lock, so nobody else takes the name meanwhile).
        aside = base
        n = 1
        aside = "#{base}-#{n += 1}" while File.exist?(aside)
        File.rename(@path, aside)
        aside
      end

      def with_lock
        FileUtils.mkdir_p(@dir)
        File.open(File.join(@dir, "approvals.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      # Writes the versioned store: one read keeps its version and the
      # keys this chi doesn't know; no file (or one that couldn't be
      # rewritten on read) starts at FORMAT's version.
      def update
        with_lock do
          list, document = read(locked: true)
          yield list
          document ||= FORMAT.read({}, collection: COLLECTION)
          write(document.with(entries: list))
        end
      end

      # A scratch session's approvals: the store's entries still apply, and
      # its own session approvals are kept in memory, so none outlives it
      # (it offers no wider scope; one that comes anyway is not kept).
      class InMemory
        def initialize(store)
          @store = store
          @own = []
          @mutex = Mutex.new
        end

        def path = @store.path

        # The store's entries, then this session's own.
        def entries = @store.entries + @mutex.synchronize { @own.dup }

        def match(verdict)
          @mutex.synchronize { Approvals.find_in(@own, verdict) } || @store.match(verdict)
        end

        def add(verdict, scope)
          return nil unless scope == "session"

          entry = Approvals.entry_for(verdict, scope)
          @mutex.synchronize { @own << entry unless @own.any? { |e| e.except("created_at") == entry.except("created_at") } }
          entry
        end

        # Index as #entries lists them: the store's first, then its own.
        def revoke(index)
          stored = @store.entries.size
          return @store.revoke(index) if index < stored

          @mutex.synchronize { index - stored < @own.size ? @own.delete_at(index - stored) : nil }
        end
      end
    end
  end
end
