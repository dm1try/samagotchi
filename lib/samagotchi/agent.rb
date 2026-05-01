# frozen_string_literal: true

require "json"
require "fileutils"
require "reline"

require_relative "kernel_loop"
require_relative "tools/memory"

module Samagotchi
  # Agent encapsulates the two operating modes of the harness.
  #
  # assist mode  — interactive REPL: user types, model responds, tools execute inline.
  # evolve mode  — autonomous: model reads its own source, extends itself, validates with rspec.
  class Agent
    AGENT_DESCRIPTION_FILE = "AGENT.md"
    PROMPT_HISTORY_ENV = "SAMAGOTCHI_HISTORY_FILE"
    XDG_STATE_HOME_ENV = "XDG_STATE_HOME"
    PROMPT_HISTORY_FILE = "history.json"
    PROMPT_HISTORY_STATE_DIR = "samagotchi"
    PROMPT_HISTORY_LIMIT = 20
    SKIP_AGENT_DESCRIPTION_ENV = "SAMAGOTCHI_SKIP_AGENT_MD"
    CONTINUE_COMMAND = "/continue"
    CONTINUE_PROMPT = "continue(yes/no/no_with_reason)> "
    THINKING_UI_ENV = "SAMAGOTCHI_THINKING_UI"
    THINKING_UI_SPINNER = "spinner"
    THINKING_UI_OFF = "off"
    THINKING_SPINNER_FRAMES = ["|", "/", "-", "\\"].freeze
    MEMORY_SPINNER_COLOR = "38;5;208"
    MEMORY_SPINNER_PREVIEW_LIMIT = 3
    MEMORY_STICKY_PREVIEW_LIMIT = 8
    THINKING_PREVIEW_WIDTH = 80
    THINKING_PREVIEW_LINES_ENV = "SAMAGOTCHI_THINKING_PREVIEW_LINES"
    THINKING_PREVIEW_LINES_DEFAULT = 1
    THINKING_PREVIEW_LINES_MAX = 3
    THINKING_TAIL_PREVIEW_BUFFER_LIMIT = 4096
    THINKING_RENDER_MIN_INTERVAL = 0.08
    THINKING_RENDER_INTERVAL_ENV = "SAMAGOTCHI_THINKING_RENDER_INTERVAL"
    AT_PATH_COMPLETION_PREFIX = "@"
    AT_PATH_COMPLETION_MAX_CANDIDATES = 200

    # ── Tool declarations (Gemma 4 <|tool>/<tool|> format) ────────────────────

    TOOL_EXECUTE = <<~DECL.strip
      <|tool>declaration:execute{
        description:<|"|>Run any shell command and see stdout, stderr, and exit code. Large output may be truncated to a head+tail preview with metadata.<|"|>,
        parameters:{
          command:{type:<|"|>string<|"|>, description:<|"|>The shell command to run<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_READ = <<~DECL.strip
      <|tool>declaration:read{
        description:<|"|>Read a file from disk. Large files may be truncated to a head+tail preview with metadata.<|"|>,
        parameters:{
          path:{type:<|"|>string<|"|>, description:<|"|>Path to the file<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_WRITE = <<~DECL.strip
      <|tool>declaration:write{
        description:<|"|>Write content to a file (parent directories are created automatically)<|"|>,
        parameters:{
          path:{type:<|"|>string<|"|>, description:<|"|>Destination file path<|"|>, required:true},
          content:{type:<|"|>string<|"|>, description:<|"|>Content to write to the file<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_EDIT = <<~DECL.strip
      <|tool>declaration:edit{
        description:<|"|>Replace an exact block of text in an existing file. The old block must appear exactly once. Before calling edit, read the file and copy old_text verbatim from the latest read output. Prefer small, minimal, unique chunks (about 3-15 lines) instead of large rewrites.<|"|>,
        parameters:{
          path:{type:<|"|>string<|"|>, description:<|"|>File path<|"|>, required:true},
          old_text:{type:<|"|>string<|"|>, description:<|"|>Exact text to replace<|"|>, required:true},
          new_text:{type:<|"|>string<|"|>, description:<|"|>Replacement text<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_MEMORY_READ = <<~DECL.strip
      <|tool>declaration:memory_read{
        description:<|"|>Read a memory entry from scoped memories. Scope is optional: if omitted, read falls back from project to system. Leave name blank to read indexes.<|"|>,
        parameters:{
          name:{type:<|"|>string<|"|>, description:<|"|>Memory entry name without .md extension; leave blank for indexes<|"|>},
          scope:{type:<|"|>string<|"|>, description:<|"|>Optional scope: project or system<|"|>}
        }
      }<tool|>
    DECL

    TOOL_MEMORY_WRITE = <<~DECL.strip
      <|tool>declaration:memory_write{
        description:<|"|>Write or update a memory entry in scoped memories. Scope is required: project or system.<|"|>,
        parameters:{
          name:{type:<|"|>string<|"|>, description:<|"|>Memory entry name without .md extension<|"|>, required:true},
          content:{type:<|"|>string<|"|>, description:<|"|>Markdown content to write<|"|>, required:true},
          scope:{type:<|"|>string<|"|>, description:<|"|>Scope to write into: project or system<|"|>, required:true}
        }
      }<tool|>
    DECL

    TOOL_CALL_HINT = 'To call a tool, emit: <|tool_call>call:NAME{param:<|"|>value<|"|>}<tool_call|>. CRITICAL: check the tool declaration for the exact parameter names and required fields!'
    RG_GUIDANCE = "For fast repository/text search, prefer `rg` (ripgrep) over `grep` when exploring files or text."
    CONTEXT_STATUS_PROTOCOL = <<~PROTOCOL
      Context budget protocol:
        You may receive synthetic system messages that start with CONTEXT_STATUS.
        Treat CONTEXT_STATUS as telemetry, not as a user request.
        If context usage is high (for example >= 80%), prioritise:
          1. clarifying ambiguous requirements before implementation,
          2. minimizing unnecessary tool calls and repetitive exploration,
          3. keeping plans and outputs concise while preserving correctness.
        Never ignore direct user instructions because of telemetry.
    PROTOCOL
    # ── System prompts ─────────────────────────────────────────────────────────

    SYSTEM_ASSIST = <<~SYS
      You are a Ruby code assistant. You have access to the following tools:

      #{TOOL_EXECUTE}
      #{TOOL_READ}
      #{TOOL_WRITE}
      #{TOOL_EDIT}
      #{TOOL_MEMORY_READ}
      #{TOOL_MEMORY_WRITE}

      #{TOOL_CALL_HINT}
      You may make multiple tool calls. After seeing tool results, continue reasoning or answer the user.

      Editing workflow:
        1. Read the target file or region immediately before calling edit.
        2. Copy old_text verbatim from that read output; do not reconstruct it from memory.
        3. Prefer the smallest unique block (about 3-15 lines) that contains the change.
        4. If edit reports not found or multiple matches, read again and retry with a smaller or more unique block.
        5. Use write for full-file rewrites or creating new files.

      Memory convention:
        Project scope: memories/ (project-local)
        System scope:  ~/.config/samagotchi/memories/ (cross-project)
        memory_read accepts optional scope (project|system).
        memory_write requires explicit scope and entry name.
        Keep each scope's index.md updated when adding/updating entries.

      #{CONTEXT_STATUS_PROTOCOL}
    SYS

    SYSTEM_EVOLVE = <<~SYS
      You are samagotchi, a self-evolving Ruby agent harness running on Gemma 4 via llama.cpp.
      Your goal: read your own source, decide what to improve or extend, implement it, and validate with RSpec.

      Available tools:

      #{TOOL_EXECUTE}
      #{TOOL_READ}
      #{TOOL_WRITE}
      #{TOOL_EDIT}
      #{TOOL_MEMORY_READ}
      #{TOOL_MEMORY_WRITE}

      #{TOOL_CALL_HINT}
      Editing workflow:
        1. Read the target file or region immediately before calling edit.
        2. Copy old_text verbatim from that read output; do not reconstruct it from memory.
        3. Prefer the smallest unique block (about 3-15 lines) that contains the change.
        4. If edit reports not found or multiple matches, read again and retry with a smaller or more unique block.
        5. Use write for full-file rewrites or creating new files.

      Source layout:
        bin/samagotchi                 CLI entry point
        lib/samagotchi/prompt.rb       Gemma 4 prompt formatter
        lib/samagotchi/client.rb       llama.cpp HTTP client
        lib/samagotchi/kernel_loop.rb  Tool-dispatch loop (add new tools here)
        lib/samagotchi/agent.rb        Role logic (this file)
        lib/samagotchi/tools/          Individual tool implementations
        memories/index.md              Memory index: one-line description per entry
        memories/                      Individual memory entries (MD files)
        spec/                          RSpec test suite

      Memory convention:
        Project scope: memories/ (project-local)
        System scope:  ~/.config/samagotchi/memories/ (cross-project)
        memory_read accepts optional scope (project|system).
        memory_write requires explicit scope and entry name.
        Keep each scope's index.md updated when adding/updating entries.
        The current indexes are injected below for your reference.

      Workflow for adding a new tool:
        1. Write lib/samagotchi/tools/<name>.rb with self.name and self.call
        2. Require it in lib/samagotchi/kernel_loop.rb and add to TOOLS
        3. Write spec/tools/<name>_spec.rb
        4. Validate: <|tool_call>call:execute{command:<|"|>bundle exec rspec spec/tools/<name>_spec.rb --no-color<|"|>}<tool_call|>

      #{CONTEXT_STATUS_PROTOCOL}

      Begin by reading your source files and deciding what to add or improve.
    SYS

    def initialize(mode:, prompt: nil, client: nil, verbose: false, log_file: nil)
      @mode   = mode.to_sym
      @prompt = prompt
      @kernel = KernelLoop.new(client: client, verbose: verbose, log_file: log_file)
    end

    def run
      return prompt_mode if @prompt

      case @mode
      when :assist then assist_loop
      when :evolve then evolve_loop
      else raise ArgumentError, "Unknown mode '#{@mode}'. Use: assist, evolve"
      end
    end

    private

    def prompt_mode
      messages = [
        { role: "system", content: system_prompt_with_index(SYSTEM_ASSIST) },
        { role: "user",   content: @prompt }
      ]
      result = run_kernel_with_thinking_feedback(messages)
      emit_result(result)
    end

    def assist_loop
      $stdout.puts banner("assist")
      load_persistent_history
      messages = [{ role: "system", content: system_prompt_with_index(SYSTEM_ASSIST) }]
      awaiting_continue = false
      interrupted_turn_checkpoint = nil

      loop do
        input = read_input(awaiting_continue: awaiting_continue)
        break if input.nil?

        if awaiting_continue
          decision, reason = continue_decision(input)

          case decision
          when :resume
            result = run_kernel_with_thinking_feedback(messages)
          when :abort
            messages = clone_messages(interrupted_turn_checkpoint) if interrupted_turn_checkpoint
            interrupted_turn_checkpoint = nil
            awaiting_continue = false
            $stdout.puts "\nmodel> interrupted turn cancelled; enter your next prompt"
            next
          when :abort_with_reason
            messages = clone_messages(interrupted_turn_checkpoint) if interrupted_turn_checkpoint
            interrupted_turn_checkpoint = nil
            messages << {
              role: "user",
              content: "I chose not to continue the interrupted turn because: #{reason}"
            }
            awaiting_continue = false
            $stdout.puts "\nmodel> interrupted turn cancelled; noted your explanation"
            next
          else
            $stdout.puts "\nmodel> answer yes, no, or no, <reason>"
            next
          end
        else
          next if input.empty?

          if continue_request?(input)
            $stdout.puts "\nmodel> nothing to continue"
            next
          end

          interrupted_turn_checkpoint = clone_messages(messages)
          messages << { role: "user", content: input }
          persist_recent_history(input)
          result = run_kernel_with_thinking_feedback(messages)
        end

        emit_result(result)
        messages = result.conversation
        awaiting_continue = result.resumable?
        interrupted_turn_checkpoint = nil unless awaiting_continue
      end

      $stdout.puts "\nbye."
    end

    def evolve_loop
      $stdout.puts banner("evolve")
      messages = [
        { role: "system", content: system_prompt_with_index(SYSTEM_EVOLVE) },
        { role: "user",   content: "Read your source files, identify improvements, implement them, and validate with rspec." }
      ]
      result = run_kernel_with_thinking_feedback(messages, max_iterations: 20)
      emit_result(result)
    end

    def banner(mode)
      host = ENV.fetch("LLAMA_HOST", "localhost")
      port = ENV.fetch("LLAMA_PORT", "8080")
      "samagotchi [#{mode}] — #{host}:#{port}\n#{"─" * 60}"
    end

    # Appends the current memory index to the base system prompt so the agent
    # is always aware of stored memories without needing to call a tool first.
    def system_prompt_with_index(base)
      project_index = read_memory_index("project")
      system_index = read_memory_index("system")
      project_description = project_specific_description
      # Enable thinking mode by injecting the control token if THINKING_MODE is not "false"
      # This allows it to be ON by default, but explicitly DISABLEABLE via ENV.
      thinking_token = ENV["THINKING_MODE"] == "false" ? "" : "<|think|>\n"
      memory_sections = [
        "Project memories:\n#{project_index}",
        "System memories:\n#{system_index}"
      ].join("\n\n")
      [thinking_token + base, rg_guidance, project_description, memory_sections].compact.join("\n")
    end

    def emit_result(result)
      finish_thinking_spinner
      emit_tool_activity(result)
      emit_active_memories_line
      $stdout.puts result.output
      return unless result.resumable?

      $stdout.puts "iteration limit reached"
    end

    def emit_active_memories_line
      line = memory_sticky_line
      return if line.empty?

      $stdout.puts line
    end

    def emit_tool_activity(result)
      activities = result.respond_to?(:tool_activity) ? Array(result.tool_activity) : []
      activities.each do |activity|
        $stdout.puts format_tool_activity_line(activity)
      end
    end

    def format_tool_activity_line(activity)
      params = activity[:params].to_s.strip
      params_suffix = params.empty? ? "" : " #{paint(params, 90)}"
      status = activity[:status].to_s
      status_color = status == "ok" ? 32 : 31
      "#{paint('tool>', 36)} #{activity[:action]} (#{activity[:tool]}#{params_suffix}): #{paint(status, status_color)}"
    end

    def paint(text, code)
      return text unless color_output?

      "\e[#{code}m#{text}\e[0m"
    end

    def color_output?
      return false unless $stdout.tty?
      return false if ENV.key?("NO_COLOR")

      ENV.fetch("TERM", "") != "dumb"
    end

    def read_memory_index(scope)
      result = Tools::MemoryRead.call("", scope: scope)
      status = result.to_s.start_with?("Error:") ? "error" : "ok"
      activity = {
        action: "reading memory",
        tool: "memory_read",
        params: "name=\"\" scope=#{scope.inspect}",
        status: status
      }
      $stdout.puts format_tool_activity_line(activity)
      result
    end

    def read_input(awaiting_continue:)
      if awaiting_continue
        prompt = color_output? ? paint(CONTINUE_PROMPT, 33) : CONTINUE_PROMPT
        input = Reline.readline(prompt, true)
        return nil if input.nil?

        return input.strip
      end

      # In multiline mode Enter submits, while Meta+Enter/Alt+Enter inserts a
      # newline on terminals that emit that distinct sequence (for example kitty).
      input = with_scoped_at_path_completion do
        Reline.readmultiline("you> ", true) { true }
      end
      return nil if input.nil?

      input.gsub(/\r\n?|\n\z/, "\n").strip
    end

    def with_scoped_at_path_completion
      previous_completion_proc = Reline.completion_proc
      Reline.completion_proc = method(:assist_path_completion_candidates).to_proc
      yield
    ensure
      Reline.completion_proc = previous_completion_proc
    end

    def assist_path_completion_candidates(word)
      token = word.to_s
      return [] unless token.start_with?(AT_PATH_COMPLETION_PREFIX)

      path_fragment = token.delete_prefix(AT_PATH_COMPLETION_PREFIX)
      build_project_path_completion_candidates(path_fragment)
    end

    def build_project_path_completion_candidates(path_fragment)
      fragment = path_fragment.to_s.tr("\\", "/")
      return [] if fragment.start_with?("/")
      return [] if fragment.split("/").include?("..")

      dir_part = ""
      entry_prefix = fragment

      if fragment.include?("/")
        dir_part = fragment.sub(%r{[^/]*\z}, "")
        entry_prefix = fragment.split("/").last.to_s
      end

      base_dir = dir_part.empty? ? Dir.pwd : File.expand_path(dir_part, Dir.pwd)
      return [] unless path_within_cwd?(base_dir)
      return [] unless File.directory?(base_dir)

      entries = Dir.children(base_dir).sort
      entries.reject! { |entry| entry.start_with?(".") } unless entry_prefix.start_with?(".")
      matches = entries.select { |entry| entry.start_with?(entry_prefix) }

      matches.first(AT_PATH_COMPLETION_MAX_CANDIDATES).map do |entry|
        relative_path = "#{dir_part}#{entry}".tr("\\", "/")
        absolute_path = File.join(base_dir, entry)
        relative_path = "#{relative_path}/" if File.directory?(absolute_path)
        "#{AT_PATH_COMPLETION_PREFIX}#{relative_path}"
      end
    rescue StandardError
      []
    end

    def path_within_cwd?(path)
      expanded = File.expand_path(path)
      cwd = Dir.pwd
      expanded == cwd || expanded.start_with?("#{cwd}#{File::SEPARATOR}")
    end

    def history_file_path
      explicit = ENV[PROMPT_HISTORY_ENV].to_s.strip
      return explicit unless explicit.empty?

      File.join(xdg_state_home, PROMPT_HISTORY_STATE_DIR, PROMPT_HISTORY_FILE)
    end

    def xdg_state_home
      configured = ENV[XDG_STATE_HOME_ENV].to_s.strip
      return configured unless configured.empty?

      File.join(Dir.home, ".local", "state")
    end

    def load_persistent_history
      entries = load_history_entries_from_disk
      entries.last(PROMPT_HISTORY_LIMIT).each { |entry| Reline::HISTORY << entry }
    rescue StandardError
      nil
    end

    def persist_recent_history(input)
      entries = normalize_history_entries(load_history_entries_from_disk)
      entries << input
      trimmed_entries = entries.last(PROMPT_HISTORY_LIMIT)
      path = history_file_path
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(trimmed_entries) + "\n")
    rescue StandardError
      nil
    end

    def load_history_entries_from_disk
      path = history_file_path
      return [] unless File.file?(path)

      raw = File.read(path)
      parsed = JSON.parse(raw)
      normalize_history_entries(parsed)
    rescue JSON::ParserError
      normalize_history_entries(raw.to_s.lines.map(&:chomp))
    rescue StandardError
      []
    end

    def normalize_history_entries(entries)
      Array(entries).map { |entry| entry.to_s.gsub(/\r\n?/, "\n").strip }.reject(&:empty?)
    end

    def continue_request?(input)
      input == CONTINUE_COMMAND
    end

    def continue_decision(input)
      normalized = input.to_s.strip
      return [:resume, nil] if normalized.empty?

      lowered = normalized.downcase
      return [:resume, nil] if lowered == CONTINUE_COMMAND || lowered == "yes" || lowered == "y"
      return [:abort, nil] if lowered == "no" || lowered == "n"

      reason_match = normalized.match(/\A(?:no|n)\s*[,:\-]\s*(.+)\z/i)
      if reason_match
        reason = reason_match[1].to_s.strip
        return [:abort, nil] if reason.empty?

        return [:abort_with_reason, reason]
      end

      [:invalid, nil]
    end

    def clone_messages(messages)
      Array(messages).map(&:dup)
    end

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

    def skip_agent_description?
      value = ENV[SKIP_AGENT_DESCRIPTION_ENV]
      value == "1" || value&.casecmp?("true")
    end

    def rg_available?
      system("command -v rg", out: File::NULL, err: File::NULL)
    end

    def rg_guidance
      RG_GUIDANCE if rg_available?
    end

    def run_kernel_with_thinking_feedback(messages, max_iterations: 10)
      @kernel.run(
        messages,
        max_iterations: max_iterations,
        on_stream_event: method(:handle_stream_event)
      )
    ensure
      finish_thinking_spinner
    end

    def handle_stream_event(event)
      case event[:type]
      when :generation_started
        reset_thinking_tail_preview
        start_thinking_spinner
      when :generation_chunk
        capture_thinking_tail_chunk(event[:content])
        tick_thinking_spinner
      when :tool_call_started
        capture_memory_tool_call(event)
      when :generation_completed
        reset_thinking_memory_names
        reset_thinking_tail_preview
        finish_thinking_spinner
      when :tool_dispatch_started
        reset_thinking_tail_preview
        finish_thinking_spinner
      end
    end

    def start_thinking_spinner
      return unless thinking_spinner_enabled?

      @thinking_spinner_active = true
      @thinking_spinner_index = 0 if @thinking_spinner_index.nil?
      @thinking_spinner_last_render_at = nil
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = false
      render_thinking_spinner
    end

    def tick_thinking_spinner
      return unless @thinking_spinner_active

      @thinking_spinner_index = (@thinking_spinner_index + 1) % THINKING_SPINNER_FRAMES.length
      render_thinking_spinner_if_due
    end

    def render_thinking_spinner_if_due
      return render_thinking_spinner if force_spinner_render?

      last = @thinking_spinner_last_render_at
      return render_thinking_spinner if last.nil?
      return if (monotonic_time - last) < thinking_render_min_interval

      render_thinking_spinner
    end

    def force_spinner_render?
      @thinking_tail_preview_dirty && !@thinking_preview_has_content
    end

    def finish_thinking_spinner
      return unless @thinking_spinner_rendered

      line_count = @thinking_spinner_lines_rendered.to_i
      line_count = 1 if line_count <= 0

      if line_count > 1
        $stdout.print("\e[#{line_count - 1}A")
      end
      $stdout.print("\r")
      line_count.times do |index|
        $stdout.print("\e[0K")
        $stdout.print("\n") if index < line_count - 1
      end
      if line_count > 1
        $stdout.print("\e[#{line_count - 1}A")
      end
      $stdout.print("\r")
      $stdout.flush
      @thinking_spinner_rendered = false
      @thinking_spinner_active = false
      @thinking_spinner_lines_rendered = 0
      @thinking_spinner_last_render_at = nil
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = false
    end

    def render_thinking_spinner
      frame = THINKING_SPINNER_FRAMES[@thinking_spinner_index % THINKING_SPINNER_FRAMES.length]
      line = thinking_spinner_status_line(frame)
      preview_lines, preview_has_content = thinking_tail_preview_lines
      if color_output?
        preview_lines = preview_lines.map { |text| paint(text, 90) }
      end
      lines = [line] + preview_lines

      move_to_thinking_spinner_origin
      $stdout.print(lines.map { |text| "#{text}\e[0K" }.join("\n"))
      $stdout.flush
      @thinking_spinner_rendered = true
      @thinking_spinner_lines_rendered = lines.length
      @thinking_spinner_last_render_at = monotonic_time
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = preview_has_content
    end

    def move_to_thinking_spinner_origin
      return unless @thinking_spinner_rendered

      line_count = @thinking_spinner_lines_rendered.to_i
      if line_count > 1
        $stdout.print("\e[#{line_count - 1}A")
      end
      $stdout.print("\r")
    end

    def capture_thinking_tail_chunk(chunk)
      return unless thinking_tail_preview_enabled?
      return if chunk.nil? || chunk.empty?

      buffer = String.new(@thinking_tail_preview_buffer.to_s)
      buffer << chunk.to_s
      @thinking_tail_preview_buffer = buffer[-THINKING_TAIL_PREVIEW_BUFFER_LIMIT, THINKING_TAIL_PREVIEW_BUFFER_LIMIT] || buffer
      @thinking_tail_preview_dirty = true
    end

    def thinking_tail_preview_enabled?
      @mode == :assist && @thinking_spinner_active
    end

    def thinking_tail_preview_line
      lines, has_content = thinking_tail_preview_lines
      return nil unless has_content

      lines.first
    end

    def thinking_tail_preview_lines
      line_count = thinking_preview_lines_count
      prefix = "model> … "
      continuation = " " * prefix.length
      first_width = [THINKING_PREVIEW_WIDTH - prefix.length, 1].max
      continuation_width = [THINKING_PREVIEW_WIDTH - continuation.length, 1].max

      text = thinking_tail_preview_text
      text = text[-thinking_tail_preview_capacity, thinking_tail_preview_capacity] || text
      chunks = [text.slice(0, first_width).to_s]
      offset = first_width
      (line_count - 1).times do
        chunks << text.slice(offset, continuation_width).to_s
        offset += continuation_width
      end

      lines = [cap_preview_line("#{prefix}#{chunks[0]}")]
      chunks.drop(1).each do |chunk|
        lines << cap_preview_line("#{continuation}#{chunk}")
      end

      [lines, !text.empty?]
    end

    def thinking_tail_preview_text
      text = @thinking_tail_preview_buffer.to_s
      return "" if text.empty?

      # Strip model control-token fragments from the tail preview.
      text = text.gsub(/<\|[^>]{1,120}>/, "")
      text = text.gsub(/<[a-z_\|]{1,40}>/, "")
      text = text.gsub(/\s+/, " ").strip
      text.empty? ? "" : text
    end

    def reset_thinking_tail_preview
      @thinking_tail_preview_buffer = String.new
      @thinking_tail_preview_dirty = false
      @thinking_preview_has_content = false
    end

    def thinking_spinner_status_line(frame)
      base = "model> thinking... #{frame}"
      memory = memory_spinner_segment_plain
      available_for_memory = [THINKING_PREVIEW_WIDTH - base.length, 0].max
      memory = cap_preview_text(memory, available_for_memory)

      return "#{base}#{memory}" unless color_output?

      "#{paint(base, 90)}#{paint(memory, MEMORY_SPINNER_COLOR)}"
    end

    def cap_preview_line(text)
      cap_preview_text(text, THINKING_PREVIEW_WIDTH)
    end

    def cap_preview_text(text, width)
      return "" if width <= 0

      value = text.to_s
      value.length > width ? value[0, width] : value
    end

    def thinking_preview_lines_count
      raw = ENV.fetch(THINKING_PREVIEW_LINES_ENV, THINKING_PREVIEW_LINES_DEFAULT.to_s).to_s.strip
      value = Integer(raw)
      value = THINKING_PREVIEW_LINES_DEFAULT unless value.positive?
      [[value, 1].max, THINKING_PREVIEW_LINES_MAX].min
    rescue ArgumentError
      THINKING_PREVIEW_LINES_DEFAULT
    end

    def thinking_tail_preview_capacity
      prefix_length = "model> … ".length
      first_width = [THINKING_PREVIEW_WIDTH - prefix_length, 1].max
      continuation_width = first_width
      first_width + ((thinking_preview_lines_count - 1) * continuation_width)
    end

    def thinking_render_min_interval
      value = ENV.fetch(THINKING_RENDER_INTERVAL_ENV, THINKING_RENDER_MIN_INTERVAL.to_s).to_f
      return THINKING_RENDER_MIN_INTERVAL unless value.positive?

      value
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def capture_memory_tool_call(event)
      call = event[:call].is_a?(Hash) ? event[:call] : {}
      memory_name = memory_name_from_tool_call(call)
      return if memory_name.nil? || memory_name.empty?

      add_unique_memory_name(:@thinking_memory_names, memory_name)
      add_unique_memory_name(:@session_memory_names, memory_name)
    end

    def add_unique_memory_name(ivar_name, value)
      names = instance_variable_get(ivar_name) || []
      names << value unless names.include?(value)
      instance_variable_set(ivar_name, names)
    end

    def memory_name_from_tool_call(call)
      tool_name = call[:name].to_s
      case tool_name
      when Tools::MemoryRead::NAME
        normalize_memory_name(call[:content])
      when Tools::Read::NAME
        memory_name_from_read_path(call[:content])
      else
        nil
      end
    end

    def normalize_memory_name(raw)
      value = raw.to_s.strip
      return nil if value.empty?

      File.basename(value, ".md")
    end

    def memory_name_from_read_path(raw_path)
      path = raw_path.to_s.strip.tr("\\", "/")
      return nil if path.empty?
      return nil unless path.match?(%r{(?:\A|/)memories/.+\.md\z})

      normalize_memory_name(path)
    end

    def memory_spinner_segment
      segment = memory_spinner_segment_plain
      return "" if segment.empty?

      color_output? ? paint(segment, MEMORY_SPINNER_COLOR) : segment
    end

    def memory_spinner_segment_plain
      names = Array(@thinking_memory_names)
      return "" if names.empty?

      visible = names.first(MEMORY_SPINNER_PREVIEW_LIMIT)
      suffix = names.length > visible.length ? ", +#{names.length - visible.length}" : ""
      " mem: #{visible.join(', ')}#{suffix}"
    end

    def memory_sticky_line
      names = Array(@session_memory_names)
      return "" if names.empty?

      visible = names.first(MEMORY_STICKY_PREVIEW_LIMIT)
      suffix = names.length > visible.length ? ", +#{names.length - visible.length}" : ""
      body = "memories> active this session: #{visible.join(', ')}#{suffix}"
      color_output? ? paint(body, MEMORY_SPINNER_COLOR) : body
    end

    def reset_thinking_memory_names
      @thinking_memory_names = []
    end

    def thinking_spinner_enabled?
      return false unless $stdout.tty?

      mode = ENV.fetch(THINKING_UI_ENV, THINKING_UI_SPINNER).to_s.strip.downcase
      return false if mode.empty? || mode == THINKING_UI_OFF || mode == "false" || mode == "0"

      mode == THINKING_UI_SPINNER && ENV.fetch("TERM", "") != "dumb"
    end
  end
end
