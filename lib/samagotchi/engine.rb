# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

require_relative "model_profile"
require_relative "kernel_loop"
require_relative "llm/backend"
require_relative "session"
require_relative "session_observer"
require_relative "tool_declarations"
require_relative "tools/memory"

module Samagotchi
  # Engine owns the core agent logic: system prompt construction, tool
  # declarations, session lifecycle, and the model↔tool loop.
  #
  # It exposes an event-based API (`on_event`) so that any UI can run
  # turns without coupling to terminal rendering.
  class Engine
    AGENT_DESCRIPTION_FILE = "AGENT.md"
    SKIP_AGENT_DESCRIPTION_ENV = "SAMAGOTCHI_SKIP_AGENT_MD"

    # Build a system prompt string for the given profile.
    # Used by specs and inspection.
    def self.system_prompt_for(profile)
      profile = ModelProfile.normalize(profile) unless profile.is_a?(ModelProfile)
      new(mode: :assist, profile: profile).send(:assist_system_prompt)
    end

    # @param mode               [Symbol] :assist or other (Engine only supports :assist)
    # @param client             [Client, nil] defaults to Client.new
    # @param verbose            [Boolean]
    # @param log_file           [String, nil]
    # @param profile            [ModelProfile, Symbol, String, nil]
    # @param session_id         [String, nil] resume an existing session
    # @param no_interrupt       [Boolean]
    # @param model_name         [String, nil] defaults from SAMAGOTCHI_MODEL
    # @param memories           [Array<String>] --memory preload list
    def initialize(mode:, client: nil, verbose: false, log_file: nil, profile: nil, session_id: nil, no_interrupt: false, model_name: nil, memories: [], kernel: nil)
      @mode = mode.to_sym
      @base_model_name = ModelProfile.required_model_name(model_name)
      @session_model_name = @base_model_name
      @client = client || Client.new
      @profile = profile ? ModelProfile.normalize(profile) : ModelProfile.from_model_name(@base_model_name)
      @kernel = kernel || KernelLoop.new(client: @client, verbose: verbose, log_file: log_file, profile: @profile, no_interrupt: no_interrupt)
      @backend = LLM::Factory.factory(provider: :native, model_name: @base_model_name, kernel: @kernel)
      @resume_session = session_id ? Session.load(session_id) : nil
      @requested_memories = Array(memories)
      @session = nil
      @session_observer = SessionObserver.new
    end

    # Subscribe a persistent observer to engine events.
    #
    # Unlike the turn-scoped `on_event:` sink, a subscribed observer keeps
    # receiving events across every `run_turn` call on this Engine. Each
    # delivery carries a locally-monotonic `event_seq`. The returned handle can
    # be used to unsubscribe later.
    # @param observer [#call] receives event hashes (with `event_seq:` merged in)
    # @return [Samagotchi::SessionObserver::SubscribedObserver] handle to unsubscribe
    def subscribe(observer:)
      @session_observer.subscribe(observer: observer)
    end

    # Unsubscribe a previously-registered observer.
    # @param handle [Samagotchi::SessionObserver::SubscribedObserver]
    # @return [Boolean] whether the observer was removed (nil/unknown never raises)
    def unsubscribe(handle:)
      @session_observer.unsubscribe(handle: handle)
    end

    # @return [Integer] total engine events emitted so far (locally monotonic)
    def event_count
      @session_observer.event_count
    end

    # Read-only snapshot of the engine's view of the current session plus the
    # live event sequence. Cheap primitive used by the bridge's reconnect-too-
    # old reset marker and the GET /session/:id/state read surface. Orthogonal
    # to the transport — safe to call before the first turn (nil session).
    #
    # @return [Hash] with keys:
    #   :status        [String, nil] current session status
    #   :message_count [Integer]   number of messages in the session
    #   :last_prompt   [String, nil] the last user prompt (empty string if none)
    #   :event_seq     [Integer]   @session_observer.event_count
    def session_state_snapshot
      {
        status: @session&.status,
        message_count: (@session&.messages || []).size,
        last_prompt: @session&.last_prompt,
        event_seq: @session_observer&.event_count
      }
    end

    # @return [String] fully built system prompt (for inspection/tests)
    def system_prompt
      @system_prompt ||= system_prompt_with_index(assist_system_prompt)
    end

    # @return [Session] current session (Engine owns create/resume)
    def session
      @session
    end

    # Run a single turn with event emission.
    #
    # Builds the system prompt + user messages, runs the kernel loop with
    # event forwarding, and returns a KernelLoop::Result.
    #
    # @param session  [Session] the session to operate on
    # @param prompt   [String] user input
    # @param on_event [Proc, nil] receives event hashes
    # @param max_iterations [Integer] max kernel iterations
    # @param cancel_controller [Client::CancellationController, nil]
    # @param max_tool_output_chars [Integer, nil] per-output char cap for the
    #   :tool_call_completed event's `output:` (nil → env/DEFAULT_MAX_TOOL_OUTPUT_CHARS)
    # @return [KernelLoop::Result]
    def run_turn(session, prompt, on_event: nil, max_iterations: 100, cancel_controller: nil, max_tool_output_chars: nil)
      # Emit turn_started event
      emit_event(on_event, {
        type: :turn_started,
        session_id: session.id,
        prompt: prompt
      })

      messages = session.messages.dup
      system_message = { role: "system", content: system_prompt_with_index(assist_system_prompt) }

      if messages.empty?
        messages = [system_message]
      elsif messages.first[:role].to_s != "system"
        messages.unshift(system_message)
      else
        messages[0] = system_message
      end

      messages << { role: "user", content: prompt }
      session.last_prompt = prompt

      result = @backend.complete(
        messages: messages,
        max_iterations: max_iterations,
        on_stream_event: build_stream_event_handler(on_event),
        cancel_controller: cancel_controller,
        model_name: @session_model_name,
        max_tool_output_chars: max_tool_output_chars
      )

      session.messages = result.conversation if result.respond_to?(:conversation) && result.conversation.is_a?(Array)

      # Emit turn_completed or turn_canceled
      if result.respond_to?(:canceled?) && result.canceled?
        emit_event(on_event, {
          type: :turn_canceled,
          cancellation_reason: result.cancellation_reason
        })
      else
        emit_event(on_event, {
          type: :turn_completed,
          result: result
        })
      end

      response = result.respond_to?(:output) ? result.output.to_s : result.to_s
      if response.strip.empty?
        session.messages << { role: "model", content: "[No response]" }
      end

      result
    end

    # Backward-compatible: runs a prompt through the kernel loop without event forwarding.
    # @param session  [Session]
    # @param prompt   [String]
    # @return [String] model response text
    def process_prompt_through_kernel(session, prompt)
      messages = session.messages.dup
      system_message = { role: "system", content: system_prompt_with_index(assist_system_prompt) }

      if messages.empty?
        messages = [system_message]
      elsif messages.first[:role].to_s != "system"
        messages.unshift(system_message)
      else
        messages[0] = system_message
      end

      messages << { role: "user", content: prompt }
      session.last_prompt = prompt

      result = @kernel.run(messages)
      session.messages = result.conversation if result.respond_to?(:conversation) && result.conversation.is_a?(Array)

      response = result.respond_to?(:output) ? result.output.to_s : result.to_s
      if response.strip.empty?
        session.messages << { role: "model", content: "[No response]" }
        "[No response]"
      else
        response
      end
    end

    # Public entrypoint for background session workers.
    # @param session  [Session]
    # @param prompt   [String]
    # @return [String] model response
    def process_background_prompt(session:, prompt:)
      process_prompt_through_kernel(session, prompt)
    end

    # Clone a messages array (shallow dup of each element).
    # @param messages [Array<Hash>]
    # @return [Array<Hash>]
    def clone_messages(messages)
      Array(messages).map(&:dup)
    end

    private

    # ── Event helpers ──────────────────────────────────────────────────────────

    # Forward raw kernel loop events and emit Engine-level events.
    def build_stream_event_handler(on_event)
      return nil unless on_event

      proc do |event|
        # Forward the raw kernel event unchanged
        emit_event(on_event, event)
      end
    end

    def emit_event(on_event, event)
      # Turn-scoped sink: receives the original event hash (no event_seq),
      # byte-for-byte unchanged. Sink errors are isolated and never break the
      # kernel loop (same as KernelLoop's own handling).
      if on_event
        begin
          on_event.call(event)
        rescue StandardError
          # Sink errors must not break the kernel loop (same as KernelLoop's own handling)
        end
      end

      # Persistent subscribers: receive a copy with a locally-monotonic
      # `event_seq`, fan out with per-subscriber error isolation.
      @session_observer.notify(event)
    end

    # ── Tool declarations ──────────────────────────────────────────────────────

    def tool_declarations
      case @profile.name
      when "qwen36"
        "<tools>\n#{JSON.pretty_generate(ToolDeclarations::QWEN_TOOLS_JSON)}\n</tools>"
      else
        # Gemma 4 format
        [
          ToolDeclarations::TOOL_EXECUTE,
          ToolDeclarations::TOOL_READ,
          ToolDeclarations::TOOL_WRITE,
          ToolDeclarations::TOOL_EDIT,
          ToolDeclarations::TOOL_MEMORY_READ,
          ToolDeclarations::TOOL_MEMORY_WRITE,
          ToolDeclarations::TOOL_TASK_CREATE,
          ToolDeclarations::TOOL_TASK_GET,
          ToolDeclarations::TOOL_TASK_LIST,
          ToolDeclarations::TOOL_TASK_STOP,
          ToolDeclarations::TOOL_TASK_WAIT,
          ToolDeclarations::TOOL_WEB_FETCH
        ].join("\n")
      end
    end

    def tool_call_hint
      case @profile.name
      when "qwen36"
        ToolDeclarations::QWEN_TOOL_CALL_HINT
      else
        ToolDeclarations::TOOL_CALL_HINT
      end
    end

    # ── System prompts ─────────────────────────────────────────────────────────

    def assist_system_prompt
      declarations = tool_declarations
      hint = tool_call_hint

      <<~SYS
        You are Chi (pronounced "chee"), the friendly name for the Samagotchi assistant harness. You have access to the following tools:

        #{declarations}

        #{hint}
        You may make multiple tool calls. After seeing tool results, continue reasoning or answer the user.

        #{ToolDeclarations::SMALL_CONTEXT_PROTOCOL}

        Editing workflow:
          1. Read the target file or line range immediately before calling edit.
          2. For exact-match mode, copy old_text verbatim from that read output; do not reconstruct it from memory.
          3. Prefer the smallest unique block (about 3-15 lines) that contains the change.
          4. For large files, prefer range mode (start_line/end_line) to minimize context.
          5. If exact-match mode reports not found or multiple matches, read again and retry with a smaller or more unique block.
          6. Use write for full-file rewrites or creating new files.

        Memory convention:
          Project scope: ~/.config/samagotchi/memories/projects/<name>_<hash>/ (project-local)
          System scope:  ~/.config/samagotchi/memories/ (cross-project)
          memory_read accepts optional scope (project|system).
          memory_write requires explicit scope and entry name.
          User prompts may contain memory shorthand like #entry_name.
          Treat #entry_name as a memory reference, not as a file path.
          If shorthand includes a scope prefix, such as #project/entry_name or #system/entry_name,
          preserve that scope when reading the memory.
          Keep each scope's index.md updated when adding/updating entries.
          Each scope's `index.md` is auto-maintained by `memory_write` (one
          managed line per entry with name/scope/date/size); free-form sections
          are preserved. The verbatim `index` write (`path: "index"`) is kept.

        #{ToolDeclarations::CONTEXT_STATUS_PROTOCOL}
      SYS
    end

    def system_prompt_with_index(base)
      project_index = read_memory_index("project")
      system_index = read_memory_index("system")
      project_description = project_specific_description
      thinking_token = if @profile.name == "gemma4" && ENV["THINKING_MODE"] != "false"
                         "<|think|>\n"
                       else
                         ""
                       end
      memory_sections = [
        "Project memories:\n#{project_index}",
        "System memories:\n#{system_index}"
      ].join("\n\n")
      [thinking_token + base, rg_guidance, project_description, current_directory, memory_sections, explicit_memory_section].compact.join("\n")
    end

    # ── Memory helpers ─────────────────────────────────────────────────────────

    def read_memory_index(scope)
      Tools::MemoryRead.call("", scope: scope)
    end

    def explicit_memory_section
      return nil if @requested_memories.empty?

      entries = []
      @activated_memory_names ||= []
      @requested_memories.each do |raw|
        names = raw.split(",").map(&:strip).reject(&:empty?)
        names.each do |name|
          scope, actual_name = split_memory_scope(name)
          body = Tools::MemoryRead.call(actual_name, scope: scope)
          if body.start_with?("Error:")
            warn "Warning: --memory '#{name}' could not be loaded (#{body})"
            next
          end
          # Record activated names so the UI can echo them in the sticky
          # status line. The memory-body injection itself stays here — the
          # Engine is the single source of truth for the system prompt.
          @activated_memory_names << actual_name
          entries << "this memory is required by the user in the current context: memory name: #{actual_name}\n#{body}"
        end
      end

      return nil if entries.empty?

      entries.join("\n\n")
    end

    # Names activated via preloaded --memory entries during system-prompt
    # construction. Exposed so the UI can surface them in the sticky status
    # line; Engine still owns the prompt, the UI owns the rendering state.
    def activated_memory_names
      @activated_memory_names ||= []
    end

    def split_memory_scope(raw)
      value = raw.to_s.strip
      if value.include?("/")
        scope, name = value.split("/", 2)
        return [scope, name] if Tools::VALID_SCOPES.include?(scope)
      end

      [nil, value]
    end

    # ── Project / rg helpers ───────────────────────────────────────────────────

    def project_specific_description
      return nil if skip_agent_description?

      path = File.join(Dir.pwd, AGENT_DESCRIPTION_FILE)
      return nil unless File.file?(path)

      content = File.read(path).strip
      return nil if content.empty?

      "Project specific description:\n#{content}"
    rescue StandardError
      nil
    end

    def current_directory
      "Current working directory:\n#{Dir.pwd}"
    rescue StandardError
      nil
    end

    def skip_agent_description?
      value = ENV[SKIP_AGENT_DESCRIPTION_ENV]
      value == "1" || value&.casecmp?("true")
    end

    def rg_available?
      system("command -v rg", out: File::NULL, err: File::NULL)
    end

    def rg_guidance
      ToolDeclarations::RG_GUIDANCE if rg_available?
    end
  end
end
