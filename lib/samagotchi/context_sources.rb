# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require_relative "atomic_file"
require_relative "memory_paths"
require_relative "paths"
require_relative "session"

module Samagotchi
  # Attached context: named external sources a session keeps fresh (a PR, a
  # thread, a script's output). A Source says how to get the text (a command,
  # or nothing for a pushed one) and why it's attached; its Snapshot is the
  # last good text; a session's Subscription is what it has seen and read.
  # Everything lives under one root, <state dir>/context/, apart from the
  # session dirs:
  #   projects/<project_key>/<name>.json           a project's Source
  #   projects/<project_key>/<name>.snapshot.json  its Snapshot
  #   sessions/<id>/<name>.json, …snapshot.json    a session's own
  #   sessions/<id>/subscriptions.json             {name => Subscription}; the worker writes it
  #   sessions/<id>/muted/<name>                   a marker: this session ignores <name>
  # The guardrails protect the root (ProtectedPaths, CHI_TEXT): a source's
  # command runs later, outside the gate.
  module ContextSources
    DIR = "context"
    NAME_RE = /\A[a-z0-9][a-z0-9-]{0,39}\z/
    # subscriptions.json shares a session's folder with its sources.
    RESERVED_NAMES = %w[subscriptions].freeze
    SCOPES = %w[session project].freeze
    MIN_EVERY_SECONDS = 30
    DEFAULT_EVERY_SECONDS = 300
    TEXT_MAX_BYTES = 1024 * 1024
    SUMMARY_MAX_CHARS = 200
    LINE_MAX_CHARS = 300
    SNAPSHOT_SUFFIX = ".snapshot.json"
    SUBSCRIPTIONS_FILE = "subscriptions.json"
    MUTED_DIR = "muted"

    # A name, a command, a value the store can't take.
    class Invalid < ArgumentError; end

    # A source's definition. +cmd+ nil: pushed only (chi context push).
    Source = Data.define(:name, :cmd, :every_seconds, :why, :hint, :scope, :added_by, :created_at) do
      def push? = cmd.nil?

      def to_h
        { "name" => name, "cmd" => cmd, "every_seconds" => every_seconds, "why" => why, "hint" => hint,
          "scope" => scope, "added_by" => added_by, "created_at" => created_at }.compact
      end

      def self.from_h(data)
        new(name: data["name"].to_s, cmd: data["cmd"], every_seconds: data["every_seconds"]&.to_i,
            why: data["why"], hint: data["hint"], scope: data["scope"].to_s, added_by: data["added_by"],
            created_at: data["created_at"])
      end
    end

    # A source's last result. +text+ nil until a fetch or push succeeds;
    # +serial+ counts the revisions (an absorb that missed some says how
    # many); +error+ is the last failure, +error_since+ when the failures
    # began (cleared by a success), so a session hears about each run of
    # failures once. +summary+, +wake+ and +hint+ come with the revision.
    Snapshot = Data.define(:text, :summary, :revision, :serial, :fetched_at, :wake, :hint, :error, :error_since) do
      def self.empty
        new(text: nil, summary: nil, revision: nil, serial: 0, fetched_at: nil, wake: false, hint: nil,
            error: nil, error_since: nil)
      end

      def to_h
        { "text" => text, "summary" => summary, "revision" => revision, "serial" => serial,
          "fetched_at" => fetched_at, "wake" => (wake ? true : nil), "hint" => hint, "error" => error,
          "error_since" => error_since }.compact
      end

      def self.from_h(data)
        new(text: data["text"], summary: data["summary"], revision: data["revision"], serial: data["serial"].to_i,
            fetched_at: data["fetched_at"], wake: data["wake"] == true, hint: data["hint"], error: data["error"],
            error_since: data["error_since"])
      end

      def text? = !text.nil?
    end

    # What one session has had of a source: +seen+ the revision its last
    # note was about (+seen_serial+ that revision's serial), +read+ the
    # revision context_read last returned, +error_seen+ the error_since it
    # was told about, +wakes_at+ when a change last woke it (C4).
    Subscription = Data.define(:name, :seen, :seen_serial, :read, :error_seen, :wakes_at) do
      def self.blank(name)
        new(name: name, seen: nil, seen_serial: 0, read: nil, error_seen: nil, wakes_at: nil)
      end

      def to_h
        { "seen" => seen, "seen_serial" => seen_serial, "read" => read, "error_seen" => error_seen,
          "wakes_at" => wakes_at }.compact
      end

      def self.from_h(name, data)
        new(name: name, seen: data["seen"], seen_serial: data["seen_serial"].to_i, read: data["read"],
            error_seen: data["error_seen"], wakes_at: data["wakes_at"])
      end
    end

    # What a command printed or a push sent (the contract, ContextSources.parse_output).
    Fetched = Data.define(:text, :summary, :wake, :hint)

    # A source as one session sees it: the definition, where it lives, and
    # +shadowed+ for a project source hidden by a session one of its name.
    Attached = Data.define(:source, :location, :shadowed) do
      def name = source.name
      def snapshot = location.snapshot(source.name)
    end

    # A folder of sources: a project's or a session's.
    Location = Data.define(:scope, :dir, :key) do
      def session? = scope == "session"

      def source_path(name) = File.join(dir, "#{ContextSources.check_name!(name)}.json")
      def snapshot_path(name) = File.join(dir, "#{ContextSources.check_name!(name)}#{SNAPSHOT_SUFFIX}")
      def lock_path(name) = File.join(dir, "#{ContextSources.check_name!(name)}.lock")

      # @return [Array<Source>] by name
      def sources
        return [] unless Dir.exist?(dir)

        Dir.children(dir).sort.filter_map do |file|
          next unless file.end_with?(".json") && !file.end_with?(SNAPSHOT_SUFFIX) && file != SUBSCRIPTIONS_FILE

          name = file.delete_suffix(".json")
          name.match?(NAME_RE) ? source(name) : nil
        end
      end

      # @return [Source, nil]
      def source(name)
        data = ContextSources.read_json(source_path(name))
        data && Source.from_h(data.merge("name" => name, "scope" => scope))
      end

      # @raise [Invalid] a source of that name exists here
      def add(source)
        FileUtils.mkdir_p(dir)
        path = source_path(source.name)
        raise Invalid, "#{source.name} is already attached here (chi context rm #{source.name} first)" if File.exist?(path)

        AtomicFile.write(path, "#{JSON.pretty_generate(source.to_h)}\n")
        source
      end

      # @return [Boolean] whether there was a source to remove
      def remove(name)
        existed = File.exist?(source_path(name))
        [source_path(name), snapshot_path(name), lock_path(name)].each { |path| FileUtils.rm_f(path) }
        existed
      end

      # @return [Snapshot] Snapshot.empty when there is none yet
      def snapshot(name)
        data = ContextSources.read_json(snapshot_path(name))
        data ? Snapshot.from_h(data) : Snapshot.empty
      end

      # @return [Time, nil] the snapshot file's mtime: the worker's cheap "anything new?"
      def snapshot_mtime(name)
        File.mtime(snapshot_path(name))
      rescue SystemCallError
        nil
      end

      def write_snapshot(name, snapshot)
        FileUtils.mkdir_p(dir)
        AtomicFile.write(snapshot_path(name), JSON.generate(snapshot.to_h))
        snapshot
      end

      # A fetch or a push that worked: a new revision, or the same text
      # fetched again (only fetched_at moves; its summary and wake are
      # ignored). Clears the error.
      # @return [Snapshot] the one written
      def record_text(name, fetched, now: Time.now)
        previous = snapshot(name)
        revision = ContextSources.revision_of(fetched.text)
        stamp = now.utc.iso8601
        written = if revision == previous.revision
                    previous.with(fetched_at: stamp, error: nil, error_since: nil)
                  else
                    Snapshot.new(text: fetched.text, revision: revision, serial: previous.serial + 1, fetched_at: stamp,
                                 summary: fetched.summary || ContextSources.plain_summary(previous.text, fetched.text),
                                 wake: fetched.wake, hint: fetched.hint || previous.hint, error: nil, error_since: nil)
                  end
        write_snapshot(name, written)
      end

      # A fetch that failed: the last good text stays.
      # @return [Snapshot] the one written
      def record_error(name, message, now: Time.now)
        previous = snapshot(name)
        # Microseconds: two runs of failures never share a start.
        stamp = now.utc.iso8601(6)
        write_snapshot(name, previous.with(error: ContextSources.one_line(message, LINE_MAX_CHARS),
                                           error_since: previous.error_since || stamp))
      end

      # Session only: the markers and the worker's subscription file.
      def muted?(name) = File.exist?(File.join(dir, MUTED_DIR, ContextSources.check_name!(name)))

      def mute(name)
        FileUtils.mkdir_p(File.join(dir, MUTED_DIR))
        FileUtils.touch(File.join(dir, MUTED_DIR, ContextSources.check_name!(name)))
      end

      def unmute(name) = FileUtils.rm_f(File.join(dir, MUTED_DIR, ContextSources.check_name!(name)))

      # @return [Hash{String => Subscription}]
      def subscriptions
        data = ContextSources.read_json(File.join(dir, SUBSCRIPTIONS_FILE)) || {}
        data.to_h { |name, value| [name, Subscription.from_h(name, value.is_a?(Hash) ? value : {})] }
      end

      def subscription(name) = subscriptions[name] || Subscription.blank(name)

      # Only the session's worker (its absorb step, its context_read) calls this.
      def write_subscriptions(subs)
        FileUtils.mkdir_p(dir)
        AtomicFile.write(File.join(dir, SUBSCRIPTIONS_FILE), JSON.generate(subs.transform_values(&:to_h)))
      end

      def update_subscription(name)
        subs = subscriptions
        subs[name] = yield(subs[name] || Subscription.blank(name))
        write_subscriptions(subs)
        subs[name]
      end
    end

    module_function

    # <state dir>/context; +state_dir+ is the sessions dir (Session.default_state_dir).
    def root(state_dir: nil)
      File.join(File.dirname(state_dir || Session.default_state_dir), DIR)
    end

    def session_location(session_id, state_dir: nil)
      Location.new(scope: "session", dir: File.join(root(state_dir: state_dir), "sessions", Session.check_id!(session_id)),
                   key: session_id)
    end

    def project_location(project_key, state_dir: nil)
      Location.new(scope: "project", dir: File.join(root(state_dir: state_dir), "projects", project_key.to_s), key: project_key)
    end

    # The project a session's sources come from: nil when it is in no repo.
    # @param project_root [String, nil] Session#project_root
    def project_location_for(project_root, state_dir: nil)
      return nil if project_root.to_s.empty?

      project_location(project_key_of(project_root), state_dir: state_dir)
    end

    # MemoryPaths.project_key for a root already resolved.
    def project_key_of(root)
      "#{File.basename(root)}_#{Digest::MD5.hexdigest(root)[0..7]}"
    end

    # A session's sources: its own, then the project's it doesn't shadow
    # (+shadowed+ lists those too, marked).
    # @return [Array<Attached>]
    def attached(session_id, project_root:, state_dir: nil, shadowed: false)
      own = session_location(session_id, state_dir: state_dir)
      list = own.sources.map { |source| Attached.new(source: source, location: own, shadowed: false) }
      project = project_location_for(project_root, state_dir: state_dir)
      return list unless project

      names = list.map(&:name)
      project.sources.each do |source|
        hidden = names.include?(source.name)
        list << Attached.new(source: source, location: project, shadowed: hidden) if !hidden || shadowed
      end
      list
    end

    # A deleted session's sources, snapshots, subscriptions and markers.
    # @return [Array<String>] the paths removed
    def remove_session(session_id, state_dir: nil)
      return [] unless Session.valid_id?(session_id.to_s)

      dir = session_location(session_id, state_dir: state_dir).dir
      return [] unless Dir.exist?(dir)

      FileUtils.rm_rf(dir)
      [dir]
    rescue SystemCallError
      []
    end

    # @return [String] +name+
    # @raise [Invalid]
    def check_name!(name)
      name = name.to_s
      unless name.match?(NAME_RE)
        raise Invalid, "#{name.inspect} isn't a source name: lowercase letters, digits and -, up to 40, starting with a letter or digit"
      end
      raise Invalid, "#{name} is a reserved name" if RESERVED_NAMES.include?(name)

      name
    end

    # @raise [Invalid] below MIN_EVERY_SECONDS or not a number
    def check_every!(value)
      return nil if value.nil?

      seconds = Integer(value.to_s, 10, exception: false)
      raise Invalid, "--every takes seconds, not #{value.inspect}" unless seconds
      raise Invalid, "--every is #{seconds}; the least is #{MIN_EVERY_SECONDS} seconds" if seconds < MIN_EVERY_SECONDS

      seconds
    end

    def revision_of(text) = Digest::SHA256.hexdigest(text.to_s)

    # The contract: stdout that parses as a JSON object with a string "text"
    # is {text, summary, wake, hint}; anything else is all text. Unknown
    # keys are ignored; summary and hint become one line, cut.
    # @return [Fetched]
    # @raise [Invalid] nothing to keep (empty, or over TEXT_MAX_BYTES)
    def parse_output(raw)
      raw = raw.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      data = json_object(raw)
      fetched = if data.is_a?(Hash) && data["text"].is_a?(String)
                  Fetched.new(text: data["text"].scrub, summary: one_line(data["summary"], SUMMARY_MAX_CHARS),
                              wake: data["wake"] == true, hint: one_line(data["hint"], LINE_MAX_CHARS))
                else
                  Fetched.new(text: raw, summary: nil, wake: false, hint: nil)
                end
      raise Invalid, "the output is empty" if fetched.text.strip.empty?
      if fetched.text.bytesize > TEXT_MAX_BYTES
        raise Invalid, "the text is #{fetched.text.bytesize} bytes; the limit is 1 MiB (#{TEXT_MAX_BYTES} bytes)"
      end

      fetched
    end

    def json_object(raw)
      return nil unless raw.lstrip.start_with?("{")

      JSON.parse(raw)
    rescue JSON::ParserError
      nil
    end

    # chi's summary of a plain-text change: "content changed (+12/−3 lines)",
    # or the size of the first text.
    def plain_summary(before, after)
      return "#{after.lines.size} #{after.lines.size == 1 ? "line" : "lines"} of text" if before.nil?

      require_relative "text_diff"
      diff = TextDiff.unified(before, after, max_lines: 0, max_bytes: 0)
      "content changed (+#{diff[:added]}/−#{diff[:removed]} lines)"
    end

    # One line, whitespace collapsed, cut at +max+ chars with "…"; nil for blank.
    def one_line(value, max)
      return nil unless value.is_a?(String)

      line = value.scrub.gsub(/\s+/, " ").strip
      return nil if line.empty?

      line.length > max ? "#{line[0, max - 1]}…" : line
    end

    def read_json(path)
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end
  end
end
