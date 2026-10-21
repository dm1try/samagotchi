# frozen_string_literal: true

require_relative "tool_activity"
require_relative "tool_row_fields"
require_relative "row_refs"
require_relative "guardrails"
require_relative "vision_context"
require_relative "log"
require_relative "edit_preview"
require_relative "tool_output_cut"
require_relative "tool_output_files"
require_relative "tools/output_guardrails"
require_relative "tools/tool_path"
require_relative "memory_bundle/index_sync"
require_relative "memory_bundle/index_size"

module Samagotchi
  # One call's result from ToolRunner#run, read by ToolResponse (the loops'
  # tool_response entries) and the loops' activity list. Fields a call didn't
  # produce (images, shown_params, shown_label, refs, diff, output_file,
  # loaded) are nil. +loaded+: the tools a find_tools hit loads
  # (Tools::ToolIndex::FoundText#loaded), by their wire names.
  ToolRun = Data.define(:output, :capped_output, :truncated, :activity, :images, :shown_params, :shown_label, :refs, :diff,
                        :output_file, :loaded) do
    def initialize(output: nil, capped_output: nil, truncated: nil, activity: nil, images: nil, shown_params: nil,
                   shown_label: nil, refs: nil, diff: nil, output_file: nil, loaded: nil)
      super
    end
  end

  # The single per-call path both loops use: the tool_call_started and
  # tool_call_completed events, the guardrail gate (before_tool_call hooks
  # and their veto), dispatch through KernelLoop, the after_tool_call hook
  # and the output cap. Both loops feed the model `capped_output:` (cut to
  # the cap by the tool's ToolOutputCut policy, with a "[cut: …]" line),
  # the text the event and the hook get too.
  class ToolRunner
    # More images in one result are left out, each with a line (a tool
    # that returns many screenshots can't flood the context).
    MAX_IMAGES_PER_RESULT = 4

    # file_before for a call that isn't an edit/write, or won't run.
    NOT_AN_EDIT = Object.new.freeze
    private_constant :NOT_AN_EDIT

    # @param kernel [KernelLoop] read lazily: Engine sets its hooks after
    #   the kernel is built.
    # @param clock [#call] monotonic seconds, for the approval wait and the
    #   dispatch time (after_tool_call's elapsed_ms)
    def initialize(kernel, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @kernel = kernel
      @clock = clock
    end

    # @param call_index [Integer] 1-based position of the call in its batch
    # @return [ToolRun] output:, capped_output:, truncated:, activity:,
    #   output_file: (the saved whole output of a cut execute result),
    #   images: (refs) when the tool returned images the model gets to see, and
    #   shown_params: the params line the live row showed, and shown_label:
    #   its label ("chrome: screenshot"), only for a tool that isn't built in
    #   (the loops save them with the result, so a reload without the plugin
    #   shows the same row), refs: its row's refs (a plugin tool's refs:,
    #   RowRefs; saved likewise), and diff: what an edit/write changed in its
    #   file (EditPreview.change; also on tool_call_completed, never in the
    #   model's output)
    def run(call, iteration:, call_index:, call_count:, on_stream_event:, max_tool_output_chars:)
      # A call_tool of one of chi's own tools runs as that tool, from here
      # on (the gate, the row, the result): rules, approvals and hooks see
      # the real call, with via: (Tools::ToolIndex#unwrap).
      call = unwrapped(call)
      params = ToolActivity.tool_activity_params(call[:name], call, registry: tools)
      # The gate runs first, so tool_call_started shows the call that runs.
      # A tool the session's toolkit leaves out skips it: no before_tool_call
      # hook, no approval card for a call that can't run (KernelLoop#dispatch
      # answers it with the not-loaded error).
      original = call.dup
      verdict = left_out?(call) ? Guardrails::Verdict.new(call: call) : evaluate(call, iteration, params)
      call = verdict.call
      params = ToolActivity.tool_activity_params(call[:name], call, registry: tools)
      label = plugin_label(call[:name])
      # Kept on the raw event for in-worker hooks and metrics, not sent to SSE clients.
      started = { type: :tool_call_started, iteration: iteration, call_count: call_count, call_index: call_index,
                  tool: call[:name], call: call.dup, params: params }
      started[:label] = label if label
      # Its row fields (ToolRowFields: title, called_as, via, view, ref, and a
      # plugin tool's refs); the worker runs in its session's working
      # directory.
      fields = ToolRowFields.for(call[:name], call, cwd: Dir.pwd)
      refs = RowRefs.for(tools && !call[:name].nil? ? tools[call[:name]]&.refs : nil, call, cwd: session_cwd)
      fields[:refs] = refs unless refs.empty?
      started.merge!(fields)
      emit(on_stream_event, started)

      # The ask comes after tool_call_started: the UI shows the tool line,
      # then the approval under it. waited_ms on tool_call_completed lets a
      # UI that times the row from tool_call_started leave the wait out.
      waited_ms = nil
      if verdict.ask?
        asked_at = @clock.call
        settle_ask(verdict)
        waited_ms = ((@clock.call - asked_at) * 1000).round
      end
      before = verdict.deny? ? NOT_AN_EDIT : file_before(call)
      index_before = before.equal?(NOT_AN_EDIT) ? nil : memory_index_size(call)
      elapsed_ms = nil
      if verdict.deny?
        result = denied(call, verdict)
      else
        dispatched_at = @clock.call
        result = dispatch(call)
        elapsed_ms = ((@clock.call - dispatched_at) * 1000).round
      end
      diff = file_change(call, before)
      if diff && refresh_memory_index(call)
        result = with_index_note(result, index_before, call)
      end
      result = approved(result, verdict) if verdict.allow? && verdict.decided_by
      result, images = attach_images(call, result) if result[:images]

      output = scrub(result[:output].to_s)
      # The tool's own text, for after_tool_call: no "[tool]" lead, no
      # ran-as line, no cap.
      tool_text = output.sub(/\A\[#{Regexp.escape(call[:name].to_s)}\](?:\n| )/, "")
      # The gate may have replaced the call (known-names corrects a near
      # miss): one leading line tells the model what actually ran.
      if (changed = changed_call_line(original, call))
        output = "#{changed}\n#{output}"
      end
      truncated = !max_tool_output_chars.nil? && output.length > max_tool_output_chars
      capped, saved = truncated ? cut(call, output, max_tool_output_chars, result) : output
      output_file = saved.path if saved.is_a?(ToolOutputFiles::Saved)

      # The call's outcome as its activity line has it (worked out from the
      # full output: ok, error, blocked, stopped); a dispatcher that raised
      # left none, an error.
      status = result[:activity].is_a?(Hash) ? result[:activity][:status] : nil
      completed = { type: :tool_call_completed, iteration: iteration, call_count: call_count, call_index: call_index,
                    tool: call[:name], output: capped, output_truncated: truncated, activity: result[:activity] }
      completed[:images] = images if images&.any?
      completed[:diff] = diff if diff
      completed[:waited_ms] = waited_ms if waited_ms
      completed[:output_file] = output_file if output_file
      # Also here: a UI that missed the start (a replay gap) builds its row
      # from this event (its title is in the activity).
      completed.merge!(fields.slice(*ToolRowFields::EVENT_KEYS))
      emit(on_stream_event, completed)
      # After the completed event: a hook's card (check-in, skills) prints
      # under the call's tool row, not before it.
      fire(:after_tool_call, { type: :after_tool_call, iteration: iteration, tool: call[:name], output: capped,
                               status: status || "error", call: call.dup, elapsed_ms: elapsed_ms, result: tool_text })

      ToolRun.new(output: output, capped_output: capped, truncated: truncated, activity: result[:activity],
                  images: images&.any? ? images : nil,
                  shown_params: params && plugin_tool?(call[:name]) ? params : nil,
                  shown_label: label, refs: refs.empty? ? nil : refs, diff: diff, output_file: output_file)
    end

    private

    # +output+ cut to +cap+ by its tool's policy (ToolOutputCut); an
    # execute result keeps its tail too, its whole output saved in the
    # session's folder.
    # @param result [Hash] the dispatch's: its ref_path is the file the
    #   whole text is in (a task's log, a child's reply: Tools::RefText),
    #   for task_wait and delegate; ref_stderr_path, a task's stderr log
    # @return [Array(String, Object)] the text, and the saved file (or why
    #   there is none) when it was cut that way
    def cut(call, output, cap, result)
      ToolOutputCut.apply(output, cap: cap, tool: call[:name], save: ->(text, dry: false) { save_output(call, text, dry: dry) },
                                  ref: result[:ref_path], ref_stderr: result[:ref_stderr_path],
                                  head_chars: Tools::OutputGuardrails.config_positive_int("execute.cut_head_chars",
                                                                                          ToolOutputCut::HEAD_CHARS))
    end

    # The whole output in the session's tool_output folder
    # (ToolOutputFiles), or why it isn't saved: no session (a bare kernel)
    # or the error's class. Never fails the call. +dry+: where it would go,
    # nothing written (ToolOutputFiles.planned).
    # @return [ToolOutputFiles::Saved, String]
    def save_output(call, text, dry: false)
      dir = session_dir
      return "no session" if dir.to_s.empty?
      return ToolOutputFiles.planned(dir, text, tool: call[:name]) if dry

      ToolOutputFiles.save(dir, text, tool: call[:name])
    rescue SystemCallError => e
      Log.warn(:turn, "tool_output_save_failed", tool: call[:name], error: e.class.name)
      e.class.name
    end

    # The session's folder (KernelLoop#session_dir), nil for a bare kernel
    # or a lookup that failed.
    def session_dir
      @kernel.respond_to?(:session_dir) ? @kernel.session_dir&.call : nil
    rescue StandardError => e
      Log.warn(:turn, "tool_output_save_failed", error: e.class.name)
      nil
    end

    # edit/write only: the file just before the call runs. The row diffs it
    # with the file after, whatever the result says, so an edit that fails
    # after writing still shows its change and one that wrote nothing shows
    # none.
    def file_before(call)
      return NOT_AN_EDIT unless EditPreview.tool?(call[:name])

      EditPreview.snapshot(Tools::ToolPath.normalize(call[:path]))
    rescue StandardError
      NOT_AN_EDIT
    end

    def file_change(call, before)
      return nil if before.equal?(NOT_AN_EDIT)

      EditPreview.change(before, EditPreview.snapshot(Tools::ToolPath.normalize(call[:path])))
    rescue StandardError => e
      Log.warn(:turn, "edit_diff_failed", tool: call[:name], error: "#{e.class}: #{e.message}")
      nil
    end

    # A write/edit that changed a memory's file refreshes its index line,
    # as memory_write does (MemoryBundle::IndexSync; a no-op elsewhere).
    def refresh_memory_index(call)
      MemoryBundle::IndexSync.refresh(Tools::ToolPath.normalize(call[:path]))
    end

    # The index size of the memory scope an edit/write's path is in
    # (MemoryBundle::IndexSize), nil for any other path, or when
    # memory.index_warn_tokens is off: other writes cost nothing.
    def memory_index_size(call)
      scope = MemoryBundle::IndexSync.memory_scope(Tools::ToolPath.normalize(call[:path]))
      return nil unless scope && MemoryBundle::IndexSize.warn_limit.positive?

      MemoryBundle::IndexSize.measure(scope)
    rescue StandardError
      nil
    end

    # +result+ with the note memory_write gives when the refreshed index
    # line took the scope's index over memory.index_warn_tokens.
    def with_index_note(result, before, call)
      return result unless before

      note = MemoryBundle::IndexSize.crossing_note(before, memory_index_size(call))
      note ? result.merge(output: "#{result[:output]}\n\n#{note}") : result
    end

    # A tool's output can hold bytes that aren't UTF-8 (`printf '\xff'`, a
    # binary file). They become "?" here, before the output reaches the
    # conversation, the events and the saved session: JSON.generate raises
    # on them, and the session would fail to save.
    def scrub(text)
      text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
      text.valid_encoding? ? text : text.scrub("?")
    end

    # A tool returned images (read an image file, or a plugin's
    # ToolResult): store each with the session (the turn's VisionContext)
    # so the loop sends it. One that can't be sent adds a line saying why
    # and keeps the text and the other images; for read, whose text only
    # says the image is attached, that line replaces the text.
    # @return [Array(Hash, Array<Hash>)] the result and its refs
    def attach_images(call, result)
      vision = @kernel.turn_settings.vision
      reason = if vision.nil? then "images can't be attached here"
               elsif !vision.sendable? then ImagePlan::CANT_SEE
               end
      refs = []
      notes = []
      Array(result[:images]).each_with_index do |entry, index|
        entry = ImageStore.symbolize(entry)
        unless valid_image_entry?(entry)
          notes << "Error: image #{index + 1} is not {path:} or {bytes:, name:}"
          next
        end

        description = entry[:description] || entry[:name] || (entry[:path] && File.basename(entry[:path])) || "image #{index + 1}"
        if reason
          notes << "#{description} is an image; #{reason}"
        elsif refs.size >= MAX_IMAGES_PER_RESULT
          notes << "#{description} is not attached: at most #{MAX_IMAGES_PER_RESULT} images per tool result"
        else
          refs << vision.ingest(entry[:path], name: entry[:name], bytes: entry[:bytes])
        end
      rescue ImageStore::Error => e
        notes << "Error: #{e.message}"
      end
      unless refs.empty?
        Log.info(:turn, "tool_images_attached", tool: call[:name], count: refs.size,
                                                bytes: refs.sum { |ref| ref[:bytes].to_i }, left_out: notes.size)
      end
      [result.merge(output: images_output(call, result, notes)), refs]
    end

    def valid_image_entry?(entry)
      return false unless entry.is_a?(Hash)

      (entry[:path].is_a?(String) && !entry[:path].empty?) || (entry[:bytes].is_a?(String) && !entry[:bytes].empty?)
    end

    def images_output(call, result, notes)
      return result[:output] if notes.empty?
      return "[#{call[:name]}] #{notes.first}" if result[:image_only] && notes.first.start_with?("Error: ")
      return "[#{call[:name]}]\n#{notes.first}" if result[:image_only]

      [result[:output], *notes].join("\n")
    end

    # The session's folder (the Engine's, KernelLoop#session_cwd), else the
    # process's: a bare kernel (specs) has none.
    def session_cwd
      cwd = @kernel.respond_to?(:session_cwd) && @kernel.session_cwd&.call
      cwd.to_s.empty? ? Dir.pwd : cwd
    end

    # The kernel's tools, for the activity line of a tool that isn't built in.
    def tools = @kernel.tools

    def layers = @kernel.respond_to?(:llm_context_layers) ? @kernel.llm_context_layers : []

    # The call its tool's entry unwraps it to (call_tool on a built-in),
    # else the call as it is. One that fails runs as it is: call_tool then
    # refuses a built-in (fail closed).
    def unwrapped(call)
      registry = tools
      return call unless registry.respond_to?(:offered) && !call[:name].nil?

      registry.offered(call[:name], layers: layers)&.unwrap&.call(call, layers) || call
    rescue StandardError => e
      Log.warn(:turn, "tool_unwrap_failed", tool: call[:name].to_s, error: "#{e.class}: #{e.message}")
      call
    end

    # A call that can't run in this turn as it is, by its name: a real tool
    # the session's toolkit leaves out, or one reached through call_tool
    # (via:) that the toolkit doesn't reach that way (a hook's rewrite).
    def left_out?(call)
      registry = tools
      return false unless registry.respond_to?(:left_out) && !call[:name].nil?
      return registry.indexed(call[:name], layers: layers).nil? if call[:via]

      !registry.left_out(call[:name], layers: layers).nil?
    end

    # A tool the registry has from a plugin (not core, not unknown).
    def plugin_tool?(name)
      entry = tools && !name.nil? ? tools[name] : nil
      !entry.nil? && !entry.core?
    end

    # A plugin tool's label, what the UIs show for its raw name.
    def plugin_label(name) = ToolActivity.plugin_label(name, registry: tools)

    # The one leading line the model gets when the gate changed the call it
    # asked for: "ran as: <tool> <changed args>", or nil when nothing
    # changed. The args are the changed call's activity params, so the line
    # stays short.
    def changed_call_line(original, call)
      return nil if original == call

      params = ToolActivity.tool_activity_params(call[:name], call, registry: tools)
      ["ran as: #{call[:name]}", params].compact.join(" ")
    end

    # The Engine sets the kernel's gate (its context, later the approval
    # flow); a bare kernel (specs) gets one that only runs the hooks.
    def gate
      @kernel.guardrail_gate || (@gate ||= Guardrails::Gate.new(-> { @kernel.hooks }, tools_lookup: -> { tools }))
    end

    # A gate that fails denies the call (fail closed).
    def evaluate(call, iteration, params)
      gate.evaluate(call, iteration: iteration, params: params)
    rescue StandardError => e
      Guardrails::Verdict.new(call: call).deny!("the guardrail check failed: #{e.class}: #{e.message}",
                                                decided_by: "core")
    end

    def settle_ask(verdict)
      gate.settle_ask(verdict)
    rescue StandardError => e
      verdict.settle!(:deny, decided_by: "core", note: "The approval failed (#{e.class}: #{e.message}).")
    end

    # An allowed ask: the activity says who allowed it, and for what scope.
    def approved(result, verdict)
      activity = result[:activity]
      activity = activity.merge(guardrail: verdict.to_activity) if activity.is_a?(Hash)
      result.merge(activity: activity)
    end

    # A legacy veto keeps its old text; a verdict's deny tells the model
    # who decided and not to route around it.
    def denied(call, verdict)
      output = if verdict.legacy?
                 reason = verdict.reason.to_s.strip
                 "[#{call[:name]}] Error: blocked by guardrail: #{reason.empty? ? "blocked by hook" : reason}"
               else
                 "[#{call[:name]}] Error: #{verdict.deny_text}"
               end
      activity = ToolActivity.tool_activity_event(call[:name], call, output, registry: tools)
      { output: output, activity: activity.merge(status: "blocked", guardrail: verdict.to_activity) }
    end

    # KernelLoop#dispatch turns tool errors into "[name] Error: …" itself;
    # this rescue only catches a failing dispatcher.
    def dispatch(call)
      @kernel.dispatch_tool_call(call)
    rescue StandardError => e
      { output: "[#{call[:name]}] Error: #{e.class}: #{e.message}", activity: nil }
    end

    # A failing hook must not break the turn.
    def fire(name, event)
      @kernel.hooks&.fire(name, event)
    rescue StandardError
      nil
    end

    def emit(callback, event)
      callback&.call(event)
    rescue StandardError
      nil
    end
  end
end
