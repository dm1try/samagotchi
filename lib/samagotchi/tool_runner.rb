# frozen_string_literal: true

require_relative "tool_activity"
require_relative "guardrails"
require_relative "vision_context"
require_relative "log"

module Samagotchi
  # The single per-call path both loops use: the tool_call_started and
  # tool_call_completed events, the guardrail gate (before_tool_call hooks
  # and their veto), dispatch through KernelLoop, the after_tool_call hook
  # and the output cap. Each loop picks what the model gets back: native
  # feeds the full `output:`, the chat loop feeds `capped_output:` (the cap
  # on the event applies to both).
  class ToolRunner
    # More images in one result are left out, each with a line (a tool
    # that returns many screenshots can't flood the context).
    MAX_IMAGES_PER_RESULT = 4

    # @param kernel [KernelLoop] read lazily: Engine sets its hooks after
    #   the kernel is built.
    def initialize(kernel)
      @kernel = kernel
    end

    # @param call_index [Integer] 1-based position of the call in its batch
    # @return [Hash] output:, capped_output:, truncated:, activity:,
    #   images: (refs) when the tool returned images the model gets to see, and
    #   shown_params: the params line the live row showed, and shown_label:
    #   its label ("chrome: screenshot"), only for a tool that isn't built in
    #   (the loops save them with the result, so a reload without the plugin
    #   shows the same row)
    def run(call, iteration:, call_index:, call_count:, on_stream_event:, max_tool_output_chars:)
      params = ToolActivity.tool_activity_params(call[:name], call, registry: tools)
      # The gate runs first, so tool_call_started shows the call that runs.
      verdict = evaluate(call, iteration, params)
      call = verdict.call
      params = ToolActivity.tool_activity_params(call[:name], call, registry: tools)
      label = plugin_label(call[:name])
      started = { type: :tool_call_started, iteration: iteration, call_count: call_count, call_index: call_index,
                  tool: call[:name], call: call.dup, params: params }
      started[:label] = label if label
      emit(on_stream_event, started)

      # The ask comes after tool_call_started: the UI shows the tool line,
      # then the approval under it.
      settle_ask(verdict) if verdict.ask?
      result = verdict.deny? ? denied(call, verdict) : dispatch(call)
      result = approved(result, verdict) if verdict.allow? && verdict.decided_by
      result, images = attach_images(call, result) if result[:images]

      output = scrub(result[:output].to_s)
      capped = output
      truncated = false
      if max_tool_output_chars && output.length > max_tool_output_chars
        truncated = true
        capped = output[0, max_tool_output_chars]
      end

      fire(:after_tool_call, { type: :after_tool_call, iteration: iteration, tool: call[:name], output: capped })
      completed = { type: :tool_call_completed, iteration: iteration, call_count: call_count, call_index: call_index,
                    tool: call[:name], output: capped, output_truncated: truncated, activity: result[:activity] }
      completed[:images] = images if images&.any?
      emit(on_stream_event, completed)

      run = { output: output, capped_output: capped, truncated: truncated, activity: result[:activity] }
      run[:images] = images if images&.any?
      run[:shown_params] = params if params && plugin_tool?(call[:name])
      run[:shown_label] = label if label
      run
    end

    private

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
      vision = @kernel.vision if @kernel.respond_to?(:vision)
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
    def tools = @kernel.respond_to?(:tools) ? @kernel.tools : nil

    # A tool the registry has from a plugin (not core, not unknown).
    def plugin_tool?(name)
      entry = tools && !name.nil? ? tools[name] : nil
      !entry.nil? && !entry.core?
    end

    # A plugin tool's label, what the UIs show for its raw name.
    def plugin_label(name) = ToolActivity.plugin_label(name, registry: tools)

    # The Engine sets the kernel's gate (its context, later the approval
    # flow); a bare kernel (specs) gets one that only runs the hooks.
    def gate
      given = @kernel.guardrail_gate if @kernel.respond_to?(:guardrail_gate)
      given || (@gate ||= Guardrails::Gate.new(-> { @kernel.hooks if @kernel.respond_to?(:hooks) }, tools_lookup: -> { tools }))
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
      hooks = @kernel.hooks if @kernel.respond_to?(:hooks)
      hooks&.fire(name, event)
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
