# frozen_string_literal: true

require_relative "../model_profile"
require_relative "../tool_call_parser"
require_relative "../tool_activity"
require_relative "../tool_view"
require_relative "../llm/native_tool_normalizer"
require_relative "../tools/builtins"
require_relative "../image_store"
require_relative "../llm_context_edit"
require_relative "../token_usage"

module Samagotchi
  module Web
    # What a saved assistant message did, for the web turn view's reload: its
    # thinking and its tool calls (name, the params line the live row shows,
    # the output from the tool_response messages after it). Two storage
    # shapes, best effort:
    #   * the native loop (a profile, llama.cpp): the raw response as content
    #     (thinking + tool-call markup, Qwen or Gemma), then one tool_response
    #     whose content joins every call's output with "\n\n---\n\n";
    #   * the chat loop (api: openai): the text without thinking, the host's
    #     reasoning as +thinking+ (older sessions have none), the calls as
    #     tool_calls ({id, name, arguments}), then one tool_response per call
    #     (tool_call_id).
    # A message that can't be read gives no parts, never an error.
    #
    # A call's images (a read image, a plugin or MCP tool's) are on its
    # tool_response: chat, per call; native, one list for every call, split
    # by the saved image_counts (older sessions without them: only a lone
    # call gets them).
    #
    # A call's chi-owned id (ToolIds, saved as tool_ids) is the part's
    # tool_id:, and an LLM context edit saved on its output (LLMContextEdit,
    # under edits) the part's edit: (.edit_marks), the row's ✂ mark.
    #
    # A plugin tool's params are what its live row showed (its preview),
    # saved with the result as tool_params (native: one per call, chat: one
    # per result); its label ("chrome: screenshot") likewise as tool_labels,
    # the part's label:. The web server has no Engine and runs no plugins, so a
    # result without them (older sessions) falls back to the given
    # registry: the built-ins', and a plugin tool's arguments as key="value"
    # from the parsers' args:, as the live row shows them for a tool
    # without a preview.
    module MessageParts
      JOINER = "\n\n---\n\n"
      # A joined output's pieces each start with "[tool]": split there first,
      # so an output that holds the joiner itself stays whole.
      JOINER_BEFORE_TAG = /\n\n---\n\n(?=\[)/
      # The row shows 300 chars and the rest on hover; a read of a big file
      # would otherwise ride along with every reload.
      OUTPUT_MAX = 2000

      QWEN_THINK = %r{<think>(.*?)</think>}m
      QWEN_OPEN_THINK = %r{\A(.*?)</think>}m # the template opened the block
      GEMMA_THOUGHT = Regexp.new("#{Regexp.escape(ModelProfile::GEMMA_THOUGHT_CHANNEL_OPEN)}(.*?)" \
                                 "(?:#{Regexp.escape(ModelProfile::GEMMA_THOUGHT_CHANNEL_CLOSE)}|\\z)", Regexp::MULTILINE)

      CallRef = Struct.new(:name, :arguments)

      module_function

      # @param message [Hash] a saved model message (symbol or string keys)
      # @param responses [Array<Hash>] the tool_response messages after it
      # @param registry [Tools::Registry] the session's tools
      # @param cwd [String, nil] the session's working directory (a file
      #   tool's title is relative to it)
      # @param marks [Hash{String => Hash}] the session's edit marks by
      #   output id (.edit_marks)
      # @return [Hash, nil] { thinking:, tools: [{ tool:, params:, title:,
      #   output:, output_truncated:, images:, tool_id:, edit: }] } with only what it found; nil for nothing
      def for_message(message, responses, registry: Tools::Builtins.default, cwd: nil, marks: {})
        content = field(message, :content).to_s
        calls = field(message, :tool_calls)
        tools = if calls.is_a?(Array) && !calls.empty?
                  native_tools(calls, responses, registry, cwd, marks)
                else
                  markup_tools(content, responses, registry, cwd, marks)
                end
        parts = {}
        thinking = [field(message, :thinking).to_s.strip, thinking_of(content)].reject(&:empty?).join("\n\n")
        parts[:thinking] = thinking unless thinking.empty?
        parts[:tools] = tools unless tools.empty?
        parts.empty? ? nil : parts
      rescue StandardError
        nil
      end

      def thinking_of(content)
        blocks = content.scan(QWEN_THINK).flatten
        if blocks.empty? && !content.include?("<think>") && (open = content[QWEN_OPEN_THINK, 1])
          blocks = [open]
        end
        blocks += content.scan(GEMMA_THOUGHT).flatten
        blocks.map(&:strip).reject(&:empty?).join("\n\n")
      end

      def markup_tools(content, responses, registry, cwd = nil, marks = {})
        calls = []
        calls.concat(ToolCallParser::Qwen.new(ModelProfile.qwen36).parse(content)) if content.include?("<tool_call>")
        calls.concat(ToolCallParser::Gemma.new(ModelProfile.gemma4).parse(content)) if content.include?("<|tool_call>")
        return [] if calls.empty?

        joined = responses.empty? ? nil : responses.map { |r| field(r, :content).to_s }.join(JOINER)
        outputs = split_outputs(joined, calls.length)
        shown = saved_list(responses, :tool_params, calls.length)
        labels = saved_list(responses, :tool_labels, calls.length)
        diffs = saved_list(responses, :tool_diffs, calls.length)
        ids = saved_list(responses, :tool_ids, calls.length)
        images = split_images(responses, calls.length)
        calls.each_with_index.map do |call, i|
          tool_part(call, outputs[i], registry, shown[i], images[i], label: labels[i], diff: diffs[i], cwd: cwd,
                                                                     tool_id: ids[i], marks: marks)
        end
      end

      # A per-call list saved with the joined result(s), or none when its
      # length doesn't match the calls.
      def saved_list(responses, key, count)
        list = responses.flat_map { |r| Array(field(r, key)) }
        list.length == count ? list : []
      end

      # Each call's images from the joined tool_response(s).
      def split_images(responses, count)
        images = responses.flat_map { |r| Array(field(r, :images)) }
        return [] if images.empty?

        counts = responses.flat_map { |r| Array(field(r, :image_counts)) }
        return count == 1 ? [images] : [] unless counts.length == count && counts.sum == images.length

        counts.map { |n| images.shift(n) }
      end

      def native_tools(calls, responses, registry, cwd = nil, marks = {})
        # By id only for an id that names one response: a server may omit
        # it (nil), send "" or repeat it; those pair by position.
        ids = responses.map { |r| field(r, :tool_call_id).to_s }
        unique = ->(id) { !id.empty? && ids.count(id) == 1 }
        by_id = responses.each_with_index.to_h { |r, i| [ids[i], r] }.select { |id, _| unique.call(id) }
        calls.each_with_index.map do |raw, i|
          ref = CallRef.new(field(raw, :name).to_s, field(raw, :arguments))
          call = LLM::NativeToolNormalizer.normalize(ref) || { name: ref.name }
          response = by_id[field(raw, :id).to_s] || (responses[i] && !unique.call(ids[i]) ? responses[i] : nil)
          tool_part(call, response && field(response, :content).to_s, registry, field(response, :tool_params),
                    response && field(response, :images), label: field(response, :tool_labels),
                                                          diff: field(response, :tool_diffs), cwd: cwd,
                                                          tool_id: Array(field(response, :tool_ids)).first, marks: marks)
        end
      end

      # The ✂ mark of each output an LLM context edit is saved on, by its
      # id, from +messages+ (a session's, symbol or string keys): {kind:
      # "stale" | "forget", staged: true while a forget waits for the
      # turn's end, note: (a stale stub's reason, "superseded by a later
      # read"; the first output of a forget_outputs call's, its note), with:
      # (the others of that call's: the first one's id), kept: ("12-40, 50",
      # a forget's kept lines)}. A forget call's outputs share the note,
      # author and stamp (LLMContextView's key); the first in the session's
      # order carries the note.
      # @return [Hash{String => Hash}]
      def edit_marks(messages)
        first = {}
        Array(messages).each_with_object({}) do |entry, marks|
          next unless field(entry, :role).to_s == "tool_response"

          saved = field(entry, :edits)
          next unless saved.is_a?(Hash)

          edits = saved.filter_map { |id, hash| LLMContextEdit.from_h(id, hash) }.to_h { |edit| [edit.id, edit] }
          order = Array(field(entry, :tool_ids)).map(&:to_s)
          edits.sort_by { |id, _| order.index(id) || order.size }.each do |id, edit|
            marks[id] = edit_mark(edit, first)
          end
        end
      rescue StandardError
        {}
      end

      def edit_mark(edit, first)
        mark = { kind: edit.kind.to_s }
        mark[:staged] = true unless edit.applied?
        if edit.kind == :stale
          mark[:note] = edit.note[/superseded by .*\z/] || edit.note
        else
          key = [edit.note, edit.by, edit.staged_at]
          if first.key?(key)
            mark[:with] = first[key]
          else
            first[key] = edit.id
            mark[:note] = edit.note
          end
          kept = edit.keep.map { |from, to| from == to ? from.to_s : "#{from}-#{to}" }
          mark[:kept] = kept.join(", ") unless kept.empty?
        end
        mark
      end

      # +output+'s ✂ mark (+marks+ by +id+); an applied stale stub says
      # what it frees: its output, ~chars/4.
      def mark_of(id, marks, output)
        mark = marks[id]
        return nil unless mark
        return mark unless mark[:kind] == "stale" && !mark[:staged] && output

        mark.merge(tokens: (output.length / TokenUsage::CHARS_PER_TOKEN).ceil)
      end

      # +count+ outputs from a joined tool_response: the "[tool]"-tagged
      # split when it gives the right count, else the plain one; extra pieces
      # stay with the last call, missing ones are nil.
      def split_outputs(joined, count)
        return [] if joined.nil?
        return [joined] if count == 1

        pieces = joined.split(JOINER_BEFORE_TAG, -1)
        pieces = joined.split(JOINER, -1) if pieces.length != count
        return pieces if pieces.length == count

        head = pieces.first(count - 1)
        rest = pieces.drop(count - 1)
        head + [rest.empty? ? nil : rest.join(JOINER)]
      end

      # +shown+ is the saved params line, when it is a String.
      # +diff+ is what an edit/write changed (EditPreview.change), saved as
      # tool_diffs. +cwd+: the session's working directory, for the title.
      # +tool_id+: its output's ToolIds id, with its ✂ mark in +marks+.
      def tool_part(call, output, registry, shown = nil, images = nil, label: nil, diff: nil, cwd: nil, tool_id: nil,
                    marks: {})
        name = call[:name].to_s
        params = shown.is_a?(String) ? shown : ToolActivity.tool_activity_params(name, call, registry: registry)
        part = { tool: name, params: params.to_s }
        title = ToolActivity.tool_title(name, call, cwd: cwd)
        part[:title] = title if title
        # The name the model called it by when that was an alias's (the
        # saved call is rebuilt by BuiltinCalls, which sets it again).
        part[:called_as] = call[:called_as] if call[:called_as]
        # Built from the saved call (never saved itself), so older sessions
        # get it too.
        view = ToolView.for(name, call)&.to_h
        part[:view] = view if view
        part[:label] = label if label.is_a?(String) && !label.empty?
        unless output.nil?
          part[:output] = output.length > OUTPUT_MAX ? output[0, OUTPUT_MAX] : output
          part[:output_truncated] = true if output.length > OUTPUT_MAX
        end
        refs = Array(images).select { |ref| ref.is_a?(Hash) }
        part[:images] = refs.map { |ref| ImageStore.symbolize(ref).slice(:file, :name, :width, :height) } unless refs.empty?
        part[:diff] = diff if diff.is_a?(Hash)
        if tool_id
          part[:tool_id] = tool_id.to_s
          mark = mark_of(tool_id.to_s, marks, output)
          part[:edit] = mark if mark
        end
        part
      end

      def field(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end
    end
  end
end
