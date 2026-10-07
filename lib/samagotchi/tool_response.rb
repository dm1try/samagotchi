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
    # and label, an edit/write's diff) and for the LLMContextView (each
    # run's chi-owned id, ToolIds, and a strategy's edits by id,
    # LLMContextEdit); the prompt never renders them.
    SAVED_KEYS = %i[tool_params tool_labels tool_diffs tool_ids edits].freeze
    # A run's "[name]" lead: the name, then a newline, a space or the end.
    LEAD = /\A\[([^\]\s]+)\](?:\n| |\z)/

    # One run's text in a joined entry: its "[name]" lead (with what
    # follows it) and the rest. A part without a lead has no name and an
    # empty lead.
    RunText = Data.define(:name, :lead, :body) do
      def text = "#{lead}#{body}"
    end

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
    # each on its own tool row), and the saved-only fields one per call:
    # +ids+ (ToolIds.next_ids) as tool_ids.
    def joined(runs, ids:)
      images = runs.flat_map { |run| Array(run[:images]) }
      entry = { role: "tool_response", content: runs.map { |run| run[:capped_output] }.join(SEPARATOR) }
      unless images.empty?
        entry[:images] = images
        entry[:image_counts] = runs.map { |run| Array(run[:images]).size }
      end
      saved = { tool_params: runs.map { |run| run[:shown_params] }, tool_labels: runs.map { |run| run[:shown_label] },
                tool_diffs: runs.map { |run| run[:diff] } }
      saved.each { |key, values| entry[key] = values if values.any? }
      entry[:tool_ids] = ids
      entry
    end

    # The chat loop's entry for one call: its capped output, paired with the
    # call by +tool_call_id+, and its chi-owned id (a one-id +ids+, as
    # #joined's tool_ids).
    def single(run, tool_call_id:, ids:)
      entry = { role: "tool_response", content: run[:capped_output], tool_call_id: tool_call_id }
      entry[:images] = run[:images] if run[:images]&.any?
      entry[:tool_params] = run[:shown_params] if run[:shown_params]
      entry[:tool_labels] = run[:shown_label] if run[:shown_label]
      entry[:tool_diffs] = run[:diff] if run[:diff]
      entry[:tool_ids] = ids
      entry
    end

    # A joined entry's +content+ split into its runs (RunText), by the
    # SEPARATOR heuristic: a part that opens with a "[name]" lead starts a
    # run, any other part is the previous run's own text (the first one a
    # run without a name). +limit+ goes to String#split (-1 keeps trailing
    # empty parts, so the texts join back to +content+).
    # @return [Array<RunText>]
    def split(content, limit = 0)
      content.to_s.split(SEPARATOR, limit).each_with_object([]) do |part, runs|
        if (match = part.match(LEAD))
          runs << RunText.new(name: match[1], lead: match[0], body: match.post_match)
        elsif runs.empty?
          runs << RunText.new(name: nil, lead: "", body: part)
        else
          runs[-1] = runs.last.with(body: "#{runs.last.body}#{SEPARATOR}#{part}")
        end
      end
    end
  end
end
