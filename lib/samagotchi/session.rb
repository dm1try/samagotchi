# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require_relative "atomic_file"
require_relative "context_note"
require_relative "llm_context_override"
require_relative "prompt_note"

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
    STATUS_ERROR = "error"
    STATUS_STOPPED = "stopped"

    # A stopped session's marker, <session dir>/stopped: a stop (chi
    # sessions stop, from another process) creates it instead of rewriting
    # the session file a worker may be saving at the same moment, and a
    # resume removes it. A file from before the marker says "stopped" in
    # its status field, which reads the same.
    STOPPED_FILE = "stopped"
    # The memory a delegate child starts with (Tools::Delegate::CHILD_MEMORIES).
    DELEGATE_MEMORY = "system/delegated"

    SORT_KEYS = %w[created_at updated_at].freeze
    SORT_ORDERS = %w[asc desc].freeze

    attr_accessor :id, :metadata_version, :mode, :model_name, :working_directory, :messages,
                  :created_at, :updated_at, :status, :last_prompt, :first_preview, :test_run,
                  :pending_question, :used_memory_names
    # Memories the session was started with (--memory) and memories hidden
    # from it (--mute): the worker rebuilds the same prompt on a respawn.
    # Names as given; the engine normalizes them.
    attr_accessor :preloaded_memory_names, :muted_memory_names
    # The model notes the session's system prompt carried at its last build
    # (Array<PromptNote>: name, scope, chars, digest; ModelNotes), set by the
    # Engine at each build (a start, a resume's or a woken worker's first
    # turn, /model) and saved, so what a session ran with can be read later.
    attr_reader :prompt_notes

    # @param notes [Array<PromptNote, Hash>] a file's hashes are read
    #   (PromptNote.list)
    def prompt_notes=(notes)
      @prompt_notes = PromptNote.list(notes)
    end
    # The name model_name was typed as when that differs from the resolved
    # ref stored in model_name (an alias: `small` for `gemma-small`), else
    # nil. The models: lookup takes it (HostRegistry#lookup_names).
    attr_accessor :model_typed
    # The project the session was started in (ProjectScope.root_for its
    # folder), stored because worktrees are deleted after a merge and a
    # deleted folder no longer leads to its repository. nil outside a repo,
    # and in files written before the field existed (see #project_root).
    attr_writer :project_root
    # The session that delegated this one (the `delegate` tool) or that a
    # plugin forked it from (ctx.sessions.fork), else nil.
    # Set before the spawn and kept on respawns, like preloaded_memory_names.
    attr_accessor :parent_id
    # Started by the `delegate` tool (a fork has a parent_id too, but isn't
    # one): see #delegate?.
    attr_writer :delegate
    # The session this one continues (SessionManager.continue_session): the
    # previous link of a chain, "the next day of the same routine", else
    # nil. Not a parent: archiving one link leaves the next alone. The chain
    # itself is derived (SessionChain), never stored.
    attr_accessor :continues
    # A `chi scratch` session: deleted when its REPL ends, and by the next
    # sweep (or `chi sessions clean`) when the process died first.
    attr_accessor :scratch
    # How the last turn ended, for the web's notifications (the hub sends
    # it in the summary): {"outcome" => "completed"|"failed"|"canceled",
    # "ended_at" => iso8601, "seconds" => Float, "origin" =>
    # "client"|"reminder"|"delegate"|"delegate_report"|"context"}; nil
    # before the first turn. delegate_report: a turn a parent ran for its
    # delegate children's reports (ChildReports); context: one an attached
    # context source's change started (Worker).
    attr_accessor :last_turn
    # The session's own llm_context values (LLMContextOverride: strategy,
    # apply rule, budget), before the model's; nil when it has none.
    # Saved, so a --resume and a respawned worker keep them; a plugin's
    # fork copies them, a delegate child starts without.
    attr_reader :llm_context

    # @param value [LLMContextOverride, Hash, nil] an empty one is nil; a
    #   file's Hash keeps the fields it can't read (LLMContextOverride.unread),
    #   saved back as they were until the session sets its own
    def llm_context=(value)
      @llm_context_unread = LLMContextOverride.unread(value)
      @llm_context = LLMContextOverride.from_file(value)
    end

    # The session file's "llm_context": the override's fields over the ones
    # it couldn't read; nil when there are none.
    def llm_context_file
      saved = @llm_context_unread.merge(@llm_context&.to_file || {})
      saved.empty? ? nil : saved
    end

    # The hook that stopped the last turn (stop_turn, or a cut with no retry
    # left), e.g. "loop-guard"; nil when it ended otherwise. Both strings
    # and symbols are read (the file's keys are strings).
    def stopped_by
      return nil unless @last_turn.is_a?(Hash)

      (@last_turn["stopped_by"] || @last_turn[:stopped_by])&.to_s
    end
    # Archived (ArchiveStore): hidden from the lists. Set by .list (with
    # include_archived); not saved in session.json.
    attr_accessor :archived

    # How many image refs a fork's seed lost (SessionManager.spawn_session
    # sets it); not saved.
    attr_accessor :seed_images_dropped

    # The warning for a model id its host's saved list doesn't have
    # (ModelProfile.model_warning; SessionManager.spawn_session sets it);
    # not saved.
    attr_accessor :model_warning

    def initialize(id:, mode:, model_name:, working_directory:, messages:, created_at:, updated_at:,
                   metadata_version: METADATA_VERSION, status: STATUS_IDLE, last_prompt: "",
                   first_preview: "", test_run: false, pending_question: nil,
                   used_memory_names: [], project_root: nil,
                   preloaded_memory_names: [], muted_memory_names: [], parent_id: nil, scratch: false,
                   last_turn: nil, model_typed: nil, delegate: false, llm_context: nil, prompt_notes: [],
                   continues: nil)
      @id = id
      @metadata_version = metadata_version
      @mode = mode
      @model_name = model_name
      @model_typed = model_typed
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
      self.prompt_notes = prompt_notes
      @project_root = project_root
      @parent_id = parent_id&.to_s
      @scratch = !!scratch
      @last_turn = last_turn
      @delegate = !!delegate
      @continues = continues&.to_s
      self.llm_context = llm_context
      @archived = false
    end

    # A `delegate` child: its turns report to its parent (ChildReports). A
    # child saved before the field is known by the memory every delegate
    # starts with; a fork is neither.
    def delegate?
      return true if @delegate
      return false unless @parent_id

      @preloaded_memory_names.include?(DELEGATE_MEMORY)
    end

    # The question this session waits on, as the lists show it: {id:, kind:}
    # with kind "question" (the model's), "approval", "hook" or "continue"
    # (the step-limit question, asked between turns); nil with
    # none. Only while a worker runs it (+live+): a question saved by a
    # worker that died waits for no one (the next worker drops it). The
    # web's summaries and `chi sessions list` both ask this.
    # @param live [Boolean] a worker owns the session now
    # @return [Hash, nil]
    def waiting_question(live:)
      pending = pending_question
      return nil unless live && pending.is_a?(Hash) && pending[:id]

      kind = pending[:kind].to_s
      relayed = pending[:relayed_to]
      relayed_to = relayed.is_a?(Hash) ? (relayed[:parent_short] || relayed["parent_short"]) : nil
      { id: pending[:id], kind: %w[approval hook continue].include?(kind) ? kind : "question", relayed_to: relayed_to }.compact
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
                         scratch: false, model_typed: nil, delegate: false, llm_context: nil, continues: nil)
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
        model_typed: model_typed,
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
        scratch: scratch,
        delegate: delegate,
        llm_context: llm_context,
        continues: continues
      )
    end

    def self.test_session_env?(env: ENV)
      env["SAMAGOTCHI_ENV"].to_s == "test" || env["RACK_ENV"].to_s == "test" || !env["CI"].to_s.strip.empty?
    end

    # Load a persisted session by its UUID.
    # Whether +session_id+ has a saved session.
    def self.exist?(session_id, state_dir: default_state_dir)
      valid_id?(session_id) && File.exist?(session_path(session_id, state_dir: state_dir))
    end

    def self.load(session_id, state_dir: default_state_dir)
      path = session_path(session_id, state_dir: state_dir)
      raise ArgumentError, "Session not found: #{session_id}" unless File.exist?(path)

      session = from_h(JSON.parse(File.read(path)))
      session.status = STATUS_STOPPED if stopped_marker?(session.id, state_dir: state_dir)
      session
    rescue JSON::ParserError => e
      raise ArgumentError, "Session file corrupted (#{session_id}): #{e.message}"
    end

    # A field a session file must have (KeyError without it).
    REQUIRED = Object.new.freeze

    # The fields of <id>.json, in the order #save writes them: key => the
    # value for a file without it (REQUIRED for the ones it must have).
    # .from_h and #to_h both go by this table; messages and
    # pending_question change key type on the way (symbols in memory,
    # strings on disk).
    FIELDS = {
      "metadata_version" => 1,
      "id" => REQUIRED,
      "mode" => REQUIRED,
      "model_name" => REQUIRED,
      "model_typed" => nil,
      "working_directory" => REQUIRED,
      "messages" => [],
      "created_at" => REQUIRED,
      "updated_at" => REQUIRED,
      "status" => STATUS_IDLE,
      "last_prompt" => "",
      "first_preview" => "",
      "test_run" => false,
      "pending_question" => nil,
      "used_memory_names" => [],
      "project_root" => nil,
      "preloaded_memory_names" => [],
      "muted_memory_names" => [],
      "prompt_notes" => [],
      "parent_id" => nil,
      "scratch" => false,
      "last_turn" => nil,
      "delegate" => false,
      "llm_context" => nil,
      "continues" => nil
    }.freeze

    # A session from a parsed session file. +messages+ false leaves the
    # conversation out (the lists' lightweight summaries).
    # @raise [KeyError] for a missing REQUIRED field
    def self.from_h(data, messages: true)
      attrs = FIELDS.to_h do |key, default|
        [key.to_sym, default.equal?(REQUIRED) ? data.fetch(key) : data.fetch(key, default)]
      end
      attrs[:messages] = messages ? Array(attrs[:messages]).map { |msg| symbolize_message_keys(msg) } : []
      pending = attrs[:pending_question]
      attrs[:pending_question] = pending.is_a?(Hash) ? symbolize_message_keys(pending) : nil
      new(**attrs)
    end

    # A prefix that names more than one session.
    class AmbiguousId < ArgumentError; end

    # A session id or a unique prefix of one (like git's): the full id. An
    # unknown one comes back as is, for the caller's own "not found"; one that
    # names several sessions raises AmbiguousId, which lists them.
    def self.resolve_id(id_or_prefix, state_dir: default_state_dir)
      id = id_or_prefix.to_s
      return id unless valid_id?(id) && !File.exist?(session_path(id, state_dir: state_dir))

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
      # An id that isn't one (hand-edited, or not ours) would be a path.
      return nil unless valid_id?(data["id"])

      session = from_h(data, messages: false)
      session.status = STATUS_STOPPED if stopped_marker?(session.id, state_dir: File.dirname(path))
      session
    rescue JSON::ParserError, KeyError, SystemCallError
      nil
    end

    # Persist the session atomically. Updates +updated_at+ in place.
    def save(state_dir: self.class.default_state_dir)
      @updated_at = Time.now.iso8601(3)
      # Persist with current metadata version so new flag is written
      @metadata_version = METADATA_VERSION
      FileUtils.mkdir_p(state_dir)

      path = self.class.session_file(@id, state_dir: state_dir)

      # Auto-compute first_preview if not yet cached and messages contain a user entry.
      compute_first_preview!

      AtomicFile.write(path, JSON.pretty_generate(to_h) + "\n")
      self
    end

    # The session as #save writes it (FIELDS, in their order).
    def to_h
      FIELDS.keys.to_h do |key|
        value = case key
                when "messages" then @messages.map { |msg| scrub_utf8(stringify_message_keys(msg)) }
                when "pending_question" then @pending_question && scrub_utf8(stringify_message_keys(@pending_question))
                when "test_run" then !!@test_run
                when "delegate" then @delegate
                when "llm_context" then llm_context_file
                when "prompt_notes" then @prompt_notes.map(&:to_file)
                when "used_memory_names", "preloaded_memory_names", "muted_memory_names"
                  Array(instance_variable_get(:"@#{key}"))
                else instance_variable_get(:"@#{key}")
                end
        [key, value]
      end
    end

    # Mark a session as errored.
    def self.mark_error(session_id, reason:, state_dir: default_state_dir)
      session = load(session_id, state_dir: state_dir)
      session.status = STATUS_ERROR
      session.last_prompt = reason.to_s
      session.save(state_dir: state_dir)
    end

    # Mark a session as stopped (STOPPED_FILE); its session file stays as
    # it is.
    # @raise [ArgumentError] when there is no such session
    def self.mark_stopped(session_id, state_dir: default_state_dir)
      raise ArgumentError, "Session not found: #{session_id}" unless exist?(session_id, state_dir: state_dir)

      dir = session_dir(session_id, state_dir: state_dir)
      FileUtils.mkdir_p(dir)
      FileUtils.touch(File.join(dir, STOPPED_FILE))
    end

    # Remove the stop marker (a resume, before its worker starts).
    def self.clear_stopped(session_id, state_dir: default_state_dir)
      FileUtils.rm_f(File.join(session_dir(session_id, state_dir: state_dir), STOPPED_FILE))
    end

    def self.stopped_marker?(session_id, state_dir: default_state_dir)
      File.exist?(File.join(session_dir(session_id, state_dir: state_dir), STOPPED_FILE))
    end

    # An id that is not a session id: it could name a path outside the
    # sessions dir ("../x", "/etc", "a/b", a NUL), or is empty.
    class InvalidId < ArgumentError; end

    # Ids are SecureRandom.uuid; anything made of letters, digits, "-" and
    # "_" (up to 128, not starting with "-") is taken, so a UUID prefix the
    # CLI resolves passes too. This is the one check every id from outside
    # (the bridge, the web routes, chi send/note, delegate) meets before it
    # becomes a path: session_dir and the session file path refuse others.
    VALID_ID = /\A[A-Za-z0-9_][A-Za-z0-9_-]{0,127}\z/

    def self.valid_id?(session_id)
      session_id.is_a?(String) && VALID_ID.match?(session_id)
    end

    # @raise [InvalidId] unless valid_id?(session_id)
    def self.check_id!(session_id)
      return session_id if valid_id?(session_id)

      raise InvalidId, "invalid session id: #{session_id.to_s[0, 80].inspect}"
    end

    # Directory for a specific session (holds IPC files alongside session.json).
    # @raise [InvalidId] for an id that isn't one (valid_id?)
    def self.session_dir(session_id, state_dir: default_state_dir)
      File.join(state_dir, check_id!(session_id))
    end

    # A session's <id>.json.
    # @raise [InvalidId] for an id that isn't one (valid_id?)
    def self.session_file(session_id, state_dir: default_state_dir)
      File.join(state_dir, "#{check_id!(session_id)}#{FILE_EXT}")
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
    # A session with only context notes so far previews by its first note
    # ("note: …"), until a message is typed.
    def compute_first_preview!
      from_note = note_preview
      return false if @first_preview && !@first_preview.empty? && @first_preview != from_note

      first_user = @messages.find { |m| m[:role].to_s == "user" || m["role"].to_s == "user" }
      preview = first_user ? self.class.preview_of(first_user[:content] || first_user["content"]) : from_note.to_s
      return false if preview.empty? || preview == @first_preview

      @first_preview = preview
      true
    end

    # The web's annotation labels (annotations.js sourceLabel), each on its
    # own line above a quote.
    QUOTE_LABEL_RE = /\AFrom (?:your thinking|your earlier step|the .{1,80} call|my earlier message):\z/

    # A prompt as a one-line preview: whitespace collapsed, cut at 80 chars.
    # A quoted or annotated message previews by what was typed under the
    # quote; a quote alone by its words, without the "> " markers or label.
    def self.preview_of(text)
      norm = preview_words(text.to_s).gsub(/\s+/, " ").strip
      norm.length > 80 ? "#{norm[0, 80]}…" : norm
    end

    def self.preview_words(text)
      lines = text.lines.map(&:strip)
      quoted = lines.select { |line| line.start_with?(">") }
      return text if quoted.empty?

      own = lines.reject { |line| line.start_with?(">") || QUOTE_LABEL_RE.match?(line) }.join("\n")
      return own unless own.strip.empty?

      quoted.map { |line| line.sub(/\A(?:>[ \t]?)+/, "") }.join("\n")
    end
    private_class_method :preview_words

    private

    # @return [String, nil] the first context note as a preview (not an
    # attached context source's: that is chi's, not something sent here)
    def note_preview
      note = @messages.find { |m| ContextNote.note?(m) && ContextNote.fetch(m, :context_source).nil? }
      return nil unless note

      text = self.class.preview_of(ContextNote.text_of(note))
      text.empty? ? nil : self.class.preview_of("note: #{text}")
    end

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
        symbolize_empty_answer(message)
      end

      # An empty-answer note's marker (TurnNote.empty) and its steps, as
      # they were saved.
      def symbolize_empty_answer(message)
        marker = message[:empty_answer]
        return message unless marker.is_a?(Hash)

        marker = marker.transform_keys(&:to_sym)
        marker[:steps] = marker[:steps].map { |step| step.is_a?(Hash) ? step.transform_keys(&:to_sym) : step } if marker[:steps].is_a?(Array)
        message.merge(empty_answer: marker)
      end

      def session_path(session_id, state_dir:)
        session_file(session_id, state_dir: state_dir)
      end
    end
  end
end
