# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require_relative "atomic_file"

require_relative "paths"
require_relative "project_scope"

module Samagotchi
  # archive_store requires this file.
  autoload :ArchiveStore, File.expand_path("archive_store", __dir__)

  class Session
    METADATA_VERSION = 3
    STATE_SUBDIR = File.join("samagotchi", "sessions")
    FILE_EXT = ".json"

    STATUS_IDLE = "idle"
    STATUS_RUNNING = "running"
    STATUS_COMPLETED = "completed"
    STATUS_ERROR = "error"
    STATUS_STOPPED = "stopped"

    SORT_KEYS = %w[created_at updated_at].freeze
    SORT_ORDERS = %w[asc desc].freeze

    attr_accessor :id, :metadata_version, :mode, :model_name, :working_directory, :messages,
                   :created_at, :updated_at, :status, :last_prompt, :first_preview, :test_run,
                   :pending_question, :used_memory_names
    # Memories the session was started with (--memory) and memories hidden
    # from it (--mute): the worker rebuilds the same prompt on a respawn.
    # Names as given; the engine normalizes them.
    attr_accessor :preloaded_memory_names, :muted_memory_names
    # The project the session was started in (ProjectScope.root_for its
    # folder), stored because worktrees are deleted after a merge and a
    # deleted folder no longer leads to its repository. nil outside a repo,
    # and in files written before the field existed (see #project_root).
    attr_writer :project_root
    # The session that delegated this one (the `delegate` tool) or that a
    # plugin forked it from (ctx.sessions.fork), else nil.
    # Set before the spawn and kept on respawns, like preloaded_memory_names.
    attr_accessor :parent_id
    # A `chi scratch` session: deleted when its REPL ends, and by the next
    # sweep (or `chi sessions clean`) when the process died first.
    attr_accessor :scratch
    # How the last turn ended, for the web's notifications (the hub sends
    # it in the summary): {"outcome" => "completed"|"failed"|"canceled",
    # "ended_at" => iso8601, "seconds" => Float, "origin" =>
    # "client"|"reminder"|"delegate"}; nil before the first turn.
    attr_accessor :last_turn
    # Archived (ArchiveStore): hidden from the lists. Set by .list (with
    # include_archived); not saved in session.json.
    attr_accessor :archived

    # How many image refs a fork's seed lost (SessionManager.spawn_session
    # sets it); not saved.
    attr_accessor :seed_images_dropped

    def initialize(id:, mode:, model_name:, working_directory:, messages:, created_at:, updated_at:,
                   metadata_version: METADATA_VERSION, status: STATUS_IDLE, last_prompt: "",
                   first_preview: "", test_run: false, pending_question: nil,
                   used_memory_names: [], project_root: nil,
                   preloaded_memory_names: [], muted_memory_names: [], parent_id: nil, scratch: false,
                   last_turn: nil)
      @id = id
      @metadata_version = metadata_version
      @mode = mode
      @model_name = model_name
      @working_directory = working_directory
      @messages = messages
      @created_at = created_at
      @updated_at = updated_at
      @status = status
      @last_prompt = last_prompt
      @first_preview = first_preview
      @test_run = !!test_run
      @pending_question = pending_question
      @used_memory_names = self.class.name_list(used_memory_names)
      @preloaded_memory_names = self.class.name_list(preloaded_memory_names)
      @muted_memory_names = self.class.name_list(muted_memory_names)
      @project_root = project_root
      @parent_id = parent_id&.to_s
      @scratch = !!scratch
      @last_turn = last_turn
      @archived = false
    end

    # The stored project root, else (a file from before the field) the
    # project of the working directory now: nil when that is in no repo or
    # gone. +cache+ is ProjectScope.root_for's, shared across one listing.
    def project_root(cache: nil)
      return @project_root if @project_root

      ProjectScope.root_for(@working_directory, cache: cache)
    end

    # A list of memory names: strings, stripped, no blanks, no repeats.
    def self.name_list(names)
      Array(names).map { |n| n.to_s.strip }.reject(&:empty?).uniq
    end

    # Build a new, unsaved session.
    # @param messages [Array<Hash>] a conversation to start from (a fork's
    #   seed); [] by default
    def self.new_session(mode:, model_name:, working_directory:, test_run: nil,
                         preloaded_memory_names: [], muted_memory_names: [], parent_id: nil, messages: [],
                         scratch: false)
      now = Time.now.iso8601(3)
      resolved_test = if test_run.nil?
                        test_session_env?
                      else
                        !!test_run
                      end
      new(
        id: SecureRandom.uuid,
        mode: mode.to_s,
        model_name: model_name.to_s,
        working_directory: working_directory.to_s,
        messages: Array(messages).map(&:dup),
        created_at: now,
        updated_at: now,
        status: STATUS_IDLE,
        first_preview: "",
        test_run: resolved_test,
        project_root: ProjectScope.root_for(working_directory),
        preloaded_memory_names: preloaded_memory_names,
        muted_memory_names: muted_memory_names,
        parent_id: parent_id,
        scratch: scratch
      )
    end

    def self.test_session_env?(env: ENV)
      env["SAMAGOTCHI_ENV"].to_s == "test" || env["RACK_ENV"].to_s == "test" || !env["CI"].to_s.strip.empty?
    end

    # Load a persisted session by its UUID.
    # Whether +session_id+ has a saved session.
    def self.exist?(session_id, state_dir: default_state_dir)
      File.exist?(session_path(session_id, state_dir: state_dir))
    end

    def self.load(session_id, state_dir: default_state_dir)
      path = session_path(session_id, state_dir: state_dir)
      raise ArgumentError, "Session not found: #{session_id}" unless File.exist?(path)

      data = JSON.parse(File.read(path))
      messages = (data["messages"] || []).map { |msg| symbolize_message_keys(msg) }
      pending = data["pending_question"]
      pending = symbolize_message_keys(pending) if pending.is_a?(Hash)
      used_mems = data["used_memory_names"] || data["used_memories"] || []
      new(
        id: data.fetch("id"),
        metadata_version: data.fetch("metadata_version", 1),
        mode: data.fetch("mode"),
        model_name: data.fetch("model_name"),
        working_directory: data.fetch("working_directory"),
        messages: messages,
        created_at: data.fetch("created_at"),
        updated_at: data.fetch("updated_at"),
        status: data.fetch("status", STATUS_IDLE),
        last_prompt: data.fetch("last_prompt", ""),
        first_preview: data.fetch("first_preview", ""),
        test_run: data.fetch("test_run", false),
        pending_question: pending,
        used_memory_names: Array(used_mems),
        project_root: data["project_root"],
        preloaded_memory_names: Array(data["preloaded_memory_names"]),
        muted_memory_names: Array(data["muted_memory_names"]),
        parent_id: data["parent_id"],
        scratch: data.fetch("scratch", false),
        last_turn: data["last_turn"]
      )
    rescue JSON::ParserError => e
      raise ArgumentError, "Session file corrupted (#{session_id}): #{e.message}"
    end

    # A prefix that names more than one session.
    class AmbiguousId < ArgumentError; end

    # A session id or a unique prefix of one (like git's): the full id. An
    # unknown one comes back as is, for the caller's own "not found"; one that
    # names several sessions raises AmbiguousId, which lists them.
    def self.resolve_id(id_or_prefix, state_dir: default_state_dir)
      id = id_or_prefix.to_s
      return id unless id.match?(/\A[\w-]+\z/) && !File.exist?(session_path(id, state_dir: state_dir))

      matches = Dir.glob(File.join(state_dir, "#{id}*#{FILE_EXT}")).map { |path| File.basename(path, FILE_EXT) }.sort
      return matches.fetch(0, id) if matches.size <= 1

      lines = matches.map do |match|
        preview = JSON.parse(File.read(session_path(match, state_dir: state_dir)))["first_preview"].to_s
        "  #{match}  #{preview}".rstrip
      rescue JSON::ParserError, SystemCallError
        "  #{match}"
      end
      raise AmbiguousId, "session id #{id} matches #{matches.size} sessions:\n#{lines.join("\n")}"
    end

    # Return all saved sessions sorted by updated_at desc by default (newest first).
    # Supports sort: created_at|updated_at and order: asc|desc.
    # +project_root+ keeps only that project's sessions (Session#project_root),
    # before offset/limit so pages count within the project.
    # Archived sessions (ArchiveStore) are left out unless +include_archived+;
    # everything built on .list follows (the lists, the summaries, the
    # retention prune, which then neither deletes nor counts them).
    def self.list(state_dir: default_state_dir, sort: "updated_at", order: "desc", limit: nil, offset: 0,
                  project_root: nil, include_archived: false)
      return [] unless Dir.exist?(state_dir)

      sort_key = SORT_KEYS.include?(sort.to_s) ? sort.to_s : "updated_at"
      sort_order = SORT_ORDERS.include?(order.to_s) ? order.to_s : "desc"

      sessions = Dir.glob(File.join(state_dir, "*#{FILE_EXT}")).filter_map { |path| summary_from_file(path) }
      sessions.each { |s| s.archived = ArchiveStore.archived?(session_dir(s.id, state_dir: state_dir)) }
      sessions.reject!(&:archived) unless include_archived
      if project_root
        roots = {}
        sessions.select! { |s| s.project_root(cache: roots) == project_root }
      end

      sorted = sessions.sort_by do |s|
        val = sort_key == "created_at" ? s.created_at : s.updated_at
        begin
          Time.iso8601(val.to_s)
        rescue ArgumentError
          Time.at(0)
        end
      end
      sorted.reverse! if sort_order == "desc"
      # Apply offset/limit if given
      off = offset.to_i
      sorted = sorted.drop(off) if off.positive?
      if limit && limit.to_i.positive?
        sorted = sorted.first(limit.to_i)
      end
      sorted
    end

    # One session file as .list reads it: the session without its messages
    # (the list is lightweight). The session hub reads files the same way,
    # so both agree on which files count.
    # @return [Session, nil] nil for a file that is corrupt, missing a
    #   required field, or gone
    def self.summary_from_file(path)
      data = JSON.parse(File.read(path))
      used_mems = data["used_memory_names"] || data["used_memories"] || []
      pending = data["pending_question"]
      new(
        id: data.fetch("id"),
        metadata_version: data.fetch("metadata_version", 1),
        mode: data.fetch("mode"),
        model_name: data.fetch("model_name"),
        working_directory: data.fetch("working_directory"),
        messages: [],
        created_at: data.fetch("created_at"),
        updated_at: data.fetch("updated_at"),
        status: data.fetch("status", STATUS_IDLE),
        last_prompt: data.fetch("last_prompt", ""),
        first_preview: data.fetch("first_preview", ""),
        test_run: data.fetch("test_run", false),
        pending_question: pending.is_a?(Hash) ? symbolize_message_keys(pending) : nil,
        used_memory_names: Array(used_mems),
        project_root: data["project_root"],
        preloaded_memory_names: Array(data["preloaded_memory_names"]),
        muted_memory_names: Array(data["muted_memory_names"]),
        parent_id: data["parent_id"],
        scratch: data.fetch("scratch", false),
        last_turn: data["last_turn"]
      )
    rescue JSON::ParserError, KeyError, SystemCallError
      nil
    end

    # Persist the session atomically. Updates +updated_at+ in place.
    def save(state_dir: self.class.default_state_dir)
      @updated_at = Time.now.iso8601(3)
      # Persist with current metadata version so new flag is written
      @metadata_version = METADATA_VERSION
      FileUtils.mkdir_p(state_dir)

      path = File.join(state_dir, "#{@id}#{FILE_EXT}")

      # Auto-compute first_preview if not yet cached and messages contain a user entry.
      compute_first_preview!

      record = {
        "metadata_version" => @metadata_version,
        "id" => @id,
        "mode" => @mode,
        "model_name" => @model_name,
        "working_directory" => @working_directory,
        "messages" => @messages.map { |msg| scrub_utf8(stringify_message_keys(msg)) },
        "created_at" => @created_at,
        "updated_at" => @updated_at,
        "status" => @status,
        "last_prompt" => @last_prompt,
        "first_preview" => @first_preview,
        "test_run" => !!@test_run,
        "pending_question" => @pending_question ? scrub_utf8(stringify_message_keys(@pending_question)) : nil,
        "used_memory_names" => Array(@used_memory_names),
        "project_root" => @project_root,
        "preloaded_memory_names" => Array(@preloaded_memory_names),
        "muted_memory_names" => Array(@muted_memory_names),
        "parent_id" => @parent_id,
        "scratch" => @scratch,
        "last_turn" => @last_turn
      }

      AtomicFile.write(path, JSON.pretty_generate(record) + "\n")
      self
    end

    # Mark a session as running.
    def self.mark_running(session_id, state_dir: default_state_dir)
      session = load(session_id, state_dir: state_dir)
      session.status = STATUS_RUNNING
      session.save(state_dir: state_dir)
    end

    # Mark a session as completed.
    def self.mark_completed(session_id, state_dir: default_state_dir)
      session = load(session_id, state_dir: state_dir)
      session.status = STATUS_COMPLETED
      session.save(state_dir: state_dir)
    end

    # Mark a session as errored.
    def self.mark_error(session_id, reason:, state_dir: default_state_dir)
      session = load(session_id, state_dir: state_dir)
      session.status = STATUS_ERROR
      session.last_prompt = reason.to_s
      session.save(state_dir: state_dir)
    end

    # Mark a session as stopped.
    def self.mark_stopped(session_id, state_dir: default_state_dir)
      session = load(session_id, state_dir: state_dir)
      session.status = STATUS_STOPPED
      session.save(state_dir: state_dir)
    end

    # Directory for a specific session (holds IPC files alongside session.json).
    def self.session_dir(session_id, state_dir: default_state_dir)
      File.join(state_dir, session_id)
    end

    # Default sessions directory path.
    def self.default_sessions_dir
      default_state_dir
    end

    # XDG-aware sessions directory.
    def self.default_state_dir(env: ENV)
      File.join(Paths.state_home(env: env), STATE_SUBDIR)
    end

    # Derive and cache the first user-message preview in the session record.
    # Returns true if the cached value was set or updated.
    def compute_first_preview!
      return false if @first_preview && !@first_preview.empty?

      first_user = @messages.find { |m| m[:role].to_s == "user" || m["role"].to_s == "user" }
      return false unless first_user

      preview = self.class.preview_of(first_user[:content] || first_user["content"])
      return false if preview.empty?

      @first_preview = preview
      true
    end

    # A prompt as a one-line preview: whitespace collapsed, cut at 80 chars.
    def self.preview_of(text)
      norm = text.to_s.gsub(/\s+/, " ").strip
      norm.length > 80 ? "#{norm[0, 80]}…" : norm
    end

    private

    def stringify_message_keys(hash)
      hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end

    # The last guard before JSON.generate, which raises on bytes that
    # aren't UTF-8: a save that raised would lose the whole conversation.
    # ToolRunner already scrubs tool output; this covers any other source.
    def scrub_utf8(obj)
      case obj
      when String
        str = obj.encoding == Encoding::UTF_8 ? obj : obj.dup.force_encoding(Encoding::UTF_8)
        str.valid_encoding? ? str : str.scrub("?")
      when Array then obj.map { |element| scrub_utf8(element) }
      when Hash then obj.to_h { |key, value| [key, scrub_utf8(value)] }
      else obj
      end
    end

    class << self
      private

      # A chat turn's tool_calls get symbol keys too ({id:, name:,
      # arguments:}); the arguments keep the model's string keys. So do
      # image refs ({file:, mime:, width:, …}).
      def symbolize_message_keys(hash)
        message = hash.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
        %i[tool_calls images].each do |key|
          next unless message[key].is_a?(Array)

          message[key] = message[key].map do |entry|
            entry.is_a?(Hash) ? entry.each_with_object({}) { |(k, v), h| h[k.to_sym] = v } : entry
          end
        end
        message
      end

      def session_path(session_id, state_dir:)
        File.join(state_dir, "#{session_id}#{FILE_EXT}")
      end
    end
  end
end
