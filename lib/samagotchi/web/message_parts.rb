# frozen_string_literal: true

require_relative "../model_profile"
require_relative "../tool_call_parser"
require_relative "../tool_activity"
require_relative "../llm/native_tool_normalizer"
require_relative "../tools/builtins"
require_relative "../image_store"

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
      GEMMA_THOUGHT = /<\|channel>thought(.*?)(?:<channel\|>|\z)/m

      CallRef = Struct.new(:name, :arguments)

      module_function

      # @param message [Hash] a saved model message (symbol or string keys)
      # @param responses [Array<Hash>] the tool_response messages after it
      # @param registry [Tools::Registry] the session's tools
      # @return [Hash, nil] { thinking:, tools: [{ tool:, params:, output:,
      #   output_truncated:, images: }] } with only what it found; nil for nothing
      def for_message(message, responses, registry: Tools::Builtins.default)
        content = field(message, :content).to_s
        calls = field(message, :tool_calls)
        tools = if calls.is_a?(Array) && !calls.empty?
                  native_tools(calls, responses, registry)
                else
                  markup_tools(content, responses, registry)
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

      def markup_tools(content, responses, registry)
        calls = []
        calls.concat(ToolCallParser::Qwen.new(ModelProfile.qwen36).parse(content)) if content.include?("<tool_call>")
        calls.concat(ToolCallParser::Gemma.new(ModelProfile.gemma4).parse(content)) if content.include?("<|tool_call>")
        return [] if calls.empty?

        joined = responses.empty? ? nil : responses.map { |r| field(r, :content).to_s }.join(JOINER)
        outputs = split_outputs(joined, calls.length)
        shown = saved_list(responses, :tool_params, calls.length)
        labels = saved_list(responses, :tool_labels, calls.length)
        images = split_images(responses, calls.length)
        calls.each_with_index.map do |call, i|
          tool_part(call, outputs[i], registry, shown[i], images[i], label: labels[i])
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

      def native_tools(calls, responses, registry)
        by_id = responses.to_h { |r| [field(r, :tool_call_id), r] }
        calls.each_with_index.map do |raw, i|
          ref = CallRef.new(field(raw, :name).to_s, field(raw, :arguments))
          call = LLM::NativeToolNormalizer.normalize(ref) || { name: ref.name }
          response = by_id[field(raw, :id)] || (field(responses[i], :tool_call_id).nil? ? responses[i] : nil)
          tool_part(call, response && field(response, :content).to_s, registry, field(response, :tool_params),
                    response && field(response, :images), label: field(response, :tool_labels))
        end
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
      def tool_part(call, output, registry, shown = nil, images = nil, label: nil)
        name = call[:name].to_s
        params = shown.is_a?(String) ? shown : ToolActivity.tool_activity_params(name, call, registry: registry)
        part = { tool: name, params: params.to_s }
        part[:label] = label if label.is_a?(String) && !label.empty?
        unless output.nil?
          part[:output] = output.length > OUTPUT_MAX ? output[0, OUTPUT_MAX] : output
          part[:output_truncated] = true if output.length > OUTPUT_MAX
        end
        refs = Array(images).select { |ref| ref.is_a?(Hash) }
        part[:images] = refs.map { |ref| ImageStore.symbolize(ref).slice(:file, :name, :width, :height) } unless refs.empty?
        part
      end

      def field(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end
    end
  end
end
