# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "../log"

module Samagotchi
  module Guardrails
    # The user's stored approvals: one JSON file under the state dir,
    # written aside and renamed under an exclusive flock (several chi
    # processes share it). An entry relaxes an ask, never a deny:
    #   session — this exact call (tool + normalized command / paths) in
    #             this session;
    #   repo    — this exact call in this repo (the cwd outside a repo);
    #   rule    — anything this rule (from this source) asks about here.
    # "once" is never stored. A file that doesn't parse is moved aside to
    # approvals.json.corrupt-<UTC time>, with a warning, and the store
    # starts empty: it only means more asks, and nothing is overwritten.
    class Approvals
      FILE = "approvals.json"
      STORED_SCOPES = %w[session repo rule].freeze

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
        read
      end

      # @param verdict [Verdict] an ask with its targets and context
      # @return [Hash, nil] the first entry that allows it
      def match(verdict)
        key = self.class.key_for(verdict)
        place = self.class.place_for(verdict)
        session_id = verdict.context&.session_id
        read.find do |e|
          case e["scope"]
          when "session" then session_id && e["session_id"] == session_id && e["key"] == key
          when "repo" then e["repo_root"] == place && e["key"] == key
          when "rule" then verdict.rule && e["rule"] == verdict.rule && e["source"] == verdict.source &&
                           e["repo_root"] == place
          end
        end
      end

      # Store the verdict's allowed scope (not "once").
      # @return [Hash, nil] the entry
      def add(verdict, scope)
        return nil unless STORED_SCOPES.include?(scope)

        entry = { "scope" => scope, "tool" => verdict.targets&.tool || verdict.call[:name].to_s,
                  "rule" => verdict.rule, "source" => verdict.source, "created_at" => Time.now.utc.iso8601 }
        case scope
        when "session" then entry.merge!("session_id" => verdict.context&.session_id, "key" => self.class.key_for(verdict))
        when "repo" then entry.merge!("repo_root" => self.class.place_for(verdict), "key" => self.class.key_for(verdict))
        when "rule" then entry["repo_root"] = self.class.place_for(verdict)
        end
        entry.compact!
        update { |list| list << entry unless list.any? { |e| e.except("created_at") == entry.except("created_at") } }
        entry
      end

      # Remove entry +index+ (0-based, as #entries lists them).
      # @return [Hash, nil] the removed entry
      def revoke(index)
        removed = nil
        update { |list| removed = list.delete_at(index) if index >= 0 && index < list.size }
        removed
      end

      # tool + the normalized command, or the sorted paths.
      def self.key_for(verdict)
        t = verdict.targets
        return "#{verdict.call[:name]}:" unless t
        return "#{t.tool}:#{t.command.to_s.strip.gsub(/\s+/, " ")}" if t.command

        "#{t.tool}:#{t.paths.sort.join("\n")}"
      end

      def self.place_for(verdict)
        t = verdict.targets
        t&.repo_root || t&.cwd || verdict.context&.cwd
      end

      private

      # @param locked [Boolean] the caller holds the store's lock
      def read(locked: false)
        return [] unless File.exist?(@path)

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
        []
      end

      def parse(text)
        data = JSON.parse(text)
        raise JSON::ParserError, "not a list" unless data.is_a?(Array)

        data.select { |e| e.is_a?(Hash) }
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
        aside = "#{@path}.corrupt-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
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

      def update
        with_lock do
          list = read(locked: true)
          yield list
          tmp = "#{@path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
          begin
            File.write(tmp, JSON.pretty_generate(list))
            File.rename(tmp, @path)
          ensure
            FileUtils.rm_f(tmp)
          end
        end
      end
    end
  end
end
