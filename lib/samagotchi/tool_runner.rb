# frozen_string_literal: true

require_relative "tool_activity"
require_relative "tool_row_fields"
require_relative "guardrails"
require_relative "vision_context"
require_relative "log"
require_relative "edit_preview"
require_relative "tools/tool_path"
require_relative "memory_bundle/index_sync"
require_relative "memory_bundle/index_size"

module Samagotchi
  # The single per-call path both loops use: the tool_call_started and
  # tool_call_completed events, the guardrail gate (before_tool_call hooks
  # and their veto), dispatch through KernelLoop, the after_tool_call hook
  # and the output cap. Both loops feed the model `capped_output:` (cut to
  # the cap with a "[cut: N of M chars …]" line), the text the event and
  # the hook get too.
  class ToolRunner
    # More images in one result are left out, each with a line (a tool
    # that returns many screenshots can't flood the context).
    MAX_IMAGES_PER_RESULT = 4

    # file_before for a call that isn't an edit/write, or won't run.
    NOT_AN_EDIT = Object.new.freeze
    private_constant :NOT_AN_EDIT

    # @param kernel [KernelLoop] read lazily: Engine sets its hooks after
    #   the kernel is built.
    # @param clock [#call] monotonic seconds, for the approval wait
    def initialize(kernel, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @kernel = kernel
      @clock = clock
    end

    # @param call_index [Integer] 1-based position of the call in its batch
    # @return [Hash] output:, capped_output:, truncated:, activity:,
    #   images: (refs) when the tool returned images the model gets to see, and
    #   shown_params: the params line the live row showed, and shown_label:
    #   its label ("chrome: screenshot"), only for a tool that isn't built in
    #   (the loops save them with the result, so a reload without the plugin
    #   shows the same row), and diff: what an edit/write changed in its
    #   file (EditPreview.change; also on tool_call_completed, never in the
    #   model's output)
    def run(call, iteration:, call_index:, call_count:, on_stream_event:, max_tool_output_chars:)
      params = ToolActivity.tool_activity_params(call[:name], call, registry: tools)
      # The gate runs first, so tool_call_started shows the call that runs.
      original = call.dup
      verdict = evaluate(call, iteration, params)
      call = verdict.call
      params = ToolActivity.tool_activity_params(call[:name], call, registry: tools)
      label = plugin_label(call[:name])
      started = { type: :tool_call_started, iteration: iteration, call_count: call_count, call_index: call_index,
                  tool: call[:name], call: call.dup, params: params }
      started[:label] = label if label
      # Its title, called_as and view (ToolRowFields); the worker runs in
      # its session's working directory.
      fields = ToolRowFields.for(call[:name], call, cwd: Dir.pwd)
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
      result = verdict.deny? ? denied(call, verdict) : dispatch(call)
      diff = file_change(call, before)
      if diff && refresh_memory_index(call)
        result = with_index_note(result, index_before, call)
      end
      result = approved(result, verdict) if verdict.allow? && verdict.decided_by
      result, images = attach_images(call, result) if result[:images]

      output = scrub(result[:output].to_s)
      # The gate may have replaced the call (known-names corrects a near
      # miss): one leading line tells the model what actually ran.
      if (changed = changed_call_line(original, call))
        output = "#{changed}\n#{output}"
      end
      truncated = !max_tool_output_chars.nil? && output.length > max_tool_output_chars
      capped = truncated ? cut(output, max_tool_output_chars) : output

      # The call's outcome as its activity line has it (worked out from the
      # full output: ok, error, blocked, stopped); a dispatcher that raised
      # left none, an error.
      status = result[:activity].is_a?(Hash) ? result[:activity][:status] : nil
      completed = { type: :tool_call_completed, iteration: iteration, call_count: call_count, call_index: call_index,
                    tool: call[:name], output: capped, output_truncated: truncated, activity: result[:activity] }
      completed[:images] = images if images&.any?
      completed[:diff] = diff if diff
      completed[:waited_ms] = waited_ms if waited_ms
      # Also here: a UI that missed the start (a replay gap) builds its row
      # from this event (its title is in the activity).
      completed.merge!(fields.slice(*ToolRowFields::EVENT_KEYS))
      emit(on_stream_event, completed)
      # After the completed event: a hook's card (check-in, skills) prints
      # under the call's tool row, not before it.
      fire(:after_tool_call, { type: :after_tool_call, iteration: iteration, tool: call[:name], output: capped,
                               status: status || "error" })

      run = { output: output, capped_output: capped, truncated: truncated, activity: result[:activity] }
      run[:images] = images if images&.any?
      run[:shown_params] = params if params && plugin_tool?(call[:name])
      run[:shown_label] = label if label
      run[:diff] = diff if diff
      run
    end

    private

    # +output+ cut to +cap+ chars, the cut line included: the model knows
    # what it didn't get. A cap smaller than the line keeps +cap+ chars and
    # the line goes past it.
    def cut(output, cap)
      keep = cap - cut_line(cap, output.length).length
      keep = cap unless keep.positive?
      "#{output[0, keep]}#{cut_line(keep, output.length)}"
    end

    def cut_line(kept, total)
      "\n[cut: #{kept} of #{total} chars; read it in parts]"
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

    # The kernel's tools, for the activity line of a tool that isn't built in.
    def tools = @kernel.tools

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
