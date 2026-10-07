# frozen_string_literal: true

module Samagotchi
  # A tool batch and the conversation entries its results become, for both
  # loops. The calls run through ToolRunner between the dispatch events;
  # what the model gets back is per format: the native loop answers a batch
  # with ONE tool_response (#joined), the chat loop each call with its own,
  # paired by tool_call_id (#single). Both feed the capped outputs
  # (max_tool_output_chars).
  module ToolResponse
    SEPARATOR = "\n\n---\n\n"
    # Saved with a result for the web's reload (a plugin tool's params line
    # and label, an edit/write's diff); the prompt never reads them.
    SAVED_KEYS = %i[tool_params tool_labels tool_diffs].freeze

    module_function

    # Runs +calls+ in order (ToolRunner#run each), yielding each run and its
    # index as it finishes. +emit+ takes the dispatch events, the runner's
    # own go to +on_stream_event+.
    # @return [Array<Hash>] the runs
    def run_batch(runner, calls, iteration:, emit:, on_stream_event:, cap:)
      emit.call({ type: :tool_dispatch_started, iteration: iteration, call_count: calls.length })
      runs = calls.each_with_index.map do |call, index|
        run = runner.run(call, iteration: iteration, call_index: index + 1, call_count: calls.length,
                               on_stream_event: on_stream_event, max_tool_output_chars: cap)
        yield run, index if block_given?
        run
      end
      emit.call({ type: :tool_dispatch_completed, iteration: iteration, call_count: calls.length })
      runs
    end

    # The runs' activity, for the turn's tool list (none for a call whose
    # dispatcher raised).
    def activities(runs)
      runs.filter_map { |run| run[:activity] }
    end

    # The native loop's entry for a batch: the capped outputs joined, every image
    # in call order with how many each call returned (the web's reload puts
    # each on its own tool row), and the saved-only fields one per call.
    def joined(runs)
      images = runs.flat_map { |run| Array(run[:images]) }
      entry = { role: "tool_response", content: runs.map { |run| run[:capped_output] }.join(SEPARATOR) }
      unless images.empty?
        entry[:images] = images
        entry[:image_counts] = runs.map { |run| Array(run[:images]).size }
      end
      saved = { tool_params: runs.map { |run| run[:shown_params] }, tool_labels: runs.map { |run| run[:shown_label] },
                tool_diffs: runs.map { |run| run[:diff] } }
      saved.each { |key, values| entry[key] = values if values.any? }
      entry
    end

    # The chat loop's entry for one call: its capped output, paired with the
    # call by +tool_call_id+.
    def single(run, tool_call_id:)
      entry = { role: "tool_response", content: run[:capped_output], tool_call_id: tool_call_id }
      entry[:images] = run[:images] if run[:images]&.any?
      entry[:tool_params] = run[:shown_params] if run[:shown_params]
      entry[:tool_labels] = run[:shown_label] if run[:shown_label]
      entry[:tool_diffs] = run[:diff] if run[:diff]
      entry
    end
  end
end
