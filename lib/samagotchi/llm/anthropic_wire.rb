# frozen_string_literal: true

require "digest"
require "json"
require_relative "../log"
require_relative "utf8_scrub"

module Samagotchi
  module LLM
    # ChatLoop's wire messages (the OpenAI shape #wire_messages builds) as a
    # Messages request's top-level system blocks and messages
    # (AnthropicMessages):
    # - the head system message → the top-level system, as text blocks: with
    #   its cache_split, two blocks, the breakpoint on the first; a later
    #   system message → user text (a mid-conversation system role is
    #   model-gated);
    # - an assistant message → its saved blocks verbatim (anthropic_content),
    #   else a text block and its tool_use blocks (arguments as the input
    #   object); one with neither is dropped;
    # - tool messages → tool_result blocks in a user message;
    # - user parts → text blocks and image blocks (a data URL as base64, an
    #   http(s) URL as a url source).
    # Consecutive messages of one role go as one message (so a turn's tool
    # results and the "[images from tool results]" message after them make
    # one user message), its tool_result blocks first (Messages wants them
    # before any other block). Empty or blank text blocks are never
    # sent; a user message left with none says PLACEHOLDER. reasoning_content
    # and cache_split never go out.
    module AnthropicWire
      PLACEHOLDER = "(empty)"
      # What Messages takes as a tool_use id.
      TOOL_ID_INVALID = /[^a-zA-Z0-9_-]/
      # What Messages takes as a tool name.
      TOOL_NAME = /\A[a-zA-Z0-9_-]{1,128}\z/
      # The content block types a model's thinking is replayed in.
      THINKING_TYPES = %w[thinking redacted_thinking].freeze
      # Blocks that can't carry a cache_control breakpoint.
      UNMARKABLE = THINKING_TYPES

      # A request's system blocks and messages.
      Translated = Data.define(:system, :messages)

      module_function

      # @param wire [Array<Hash>] ChatLoop's wire messages (symbol or string keys)
      # @param cache [Hash, nil] the cache_control the breakpoints carry
      #   (PromptCache.control): on the head system's first block and on the
      #   last block that didn't come from a later system message (a tail
      #   note moves each request, as PromptCache's rule says); nil sets none
      # @return [Translated]
      def translate(wire, cache: nil)
        system = []
        messages = []
        notes = {}.compare_by_identity
        Array(wire).each_with_index do |raw, index|
          message = raw.to_h.transform_keys(&:to_sym)
          role = message[:role].to_s
          if role == "system" && index.zero?
            system = system_blocks(message[:content], message[:cache_split], cache)
            next
          end

          case role
          when "assistant" then append(messages, "assistant", assistant_blocks(message))
          when "tool" then append(messages, "user", [tool_result(message)])
          when "system"
            blocks = content_blocks(message[:content])
            blocks.each { |block| notes[block] = true }
            append(messages, "user", blocks)
          else append(messages, "user", content_blocks(message[:content]))
          end
        end
        messages.each { |message| message[:content] << text_block(PLACEHOLDER) if message[:content].empty? }
        mark_last(messages, cache, notes) if cache
        Translated.new(system: system, messages: messages)
      end

      # ChatLoop's function definitions as Messages tools.
      # @param tools [Array<Hash>] {type: "function", function: {name:, description:, parameters:}}
      def tools(tools)
        Array(tools).map do |tool|
          function = (tool[:function] || tool["function"] || tool).to_h.transform_keys(&:to_sym)
          { name: function[:name].to_s, description: function[:description],
            input_schema: function[:parameters] || { type: "object", properties: {} } }.compact
        end
      end

      # A replayed thinking block's identity, the one name the adapter and
      # ChatLoop share for it: a thinking block's signature, a
      # redacted_thinking block's data, or, when that is empty (Splash
      # sends signature ""), "text:" + the SHA256 of its thinking text. nil
      # for any other block and for one with neither (never matched).
      # String or symbol keys.
      def block_identity(block)
        return nil unless block.is_a?(Hash)

        case type_of(block)
        when "thinking"
          signature = (block["signature"] || block[:signature]).to_s
          return signature unless signature.empty?

          text = (block["thinking"] || block[:thinking]).to_s
          text.empty? ? nil : "text:#{Digest::SHA256.hexdigest(text)}"
        when "redacted_thinking"
          data = (block["data"] || block[:data]).to_s
          data.empty? ? nil : data
        end
      end

      # Whether +block+ is a thinking or redacted_thinking block (a Hash,
      # string or symbol keys).
      def thinking_block?(block) = block.is_a?(Hash) && THINKING_TYPES.include?(type_of(block))

      # +id+ as Messages takes it (^[a-zA-Z0-9_-]+$), the same in tool_use
      # and tool_result: a valid id as it is, another with its invalid
      # characters replaced and a short hash of it appended (so "a.b" and
      # "a_b" stay apart).
      def tool_id(id)
        text = id.to_s
        return text if !text.empty? && !text.match?(TOOL_ID_INVALID)

        "#{text.gsub(TOOL_ID_INVALID, "_")}_#{Digest::SHA256.hexdigest(text)[0, 8]}"
      end

      # A tool name as Messages takes it (TOOL_NAME): a model's malformed one
      # ("get_weather\n</parameter", a streaming glitch) would 400 every
      # later request once sent back.
      def tool_name(name)
        text = name.to_s
        return text if text.match?(TOOL_NAME)

        text = text.gsub(TOOL_ID_INVALID, "_")[0, 128]
        text.empty? ? "tool" : text
      end

      # A message joins the one before it when the role is the same; an
      # assistant message with no blocks is dropped.
      def append(messages, role, blocks)
        return if role == "assistant" && blocks.empty?

        if messages.last && messages.last[:role] == role
          content = messages.last[:content].concat(blocks)
          results, rest = content.partition { |block| type_of(block) == "tool_result" }
          messages.last[:content] = results + rest
        else
          messages << { role: role, content: blocks }
        end
      end

      def system_blocks(content, split, cache)
        text = scrub(content.to_s)
        return [] if blank?(text)

        head = split.is_a?(Integer) && split.positive? && split < text.length ? text[0, split] : text
        tail = head.length < text.length ? text[head.length..] : ""
        first = text_block(head)
        first[:cache_control] = cache if cache
        blank?(tail) ? [first] : [first, text_block(tail)]
      end

      # The saved blocks go back as they came (string keys); otherwise the
      # text, then the calls.
      def assistant_blocks(message)
        saved = message[:anthropic_content]
        return saved.map { |block| valid_tool_use(block) } if saved.is_a?(Array) && !saved.empty?

        blocks = content_blocks(message[:content])
        Array(message[:tool_calls]).each do |raw|
          call = raw.to_h.transform_keys(&:to_sym)
          function = (call[:function] || {}).to_h.transform_keys(&:to_sym)
          name = function[:name].to_s
          blocks << { type: "tool_use", id: tool_id(call[:id]), name: tool_name(name), input: input_of(function[:arguments], name) }
        end
        blocks
      end

      # A saved block as it came, but a tool_use's name made valid and its
      # id mapped as its tool_result's is (#tool_id: a provider may answer
      # an id such as "functions.get_weather:0", which Messages refuses
      # sent back, and the result would name another id).
      def valid_tool_use(block)
        return block.dup unless block.is_a?(Hash) && type_of(block) == "tool_use"

        name_key = block.key?("name") ? "name" : :name
        id_key = block.key?("id") ? "id" : :id
        block.merge(name_key => tool_name(block[name_key]), id_key => tool_id(block[id_key]))
      end

      # A tool call's arguments as the input object: ChatLoop sends a JSON
      # String (raw when it was invalid, for a paired call): one that isn't
      # an object goes as {}.
      def input_of(arguments, name)
        return arguments if arguments.is_a?(Hash)

        text = arguments.to_s
        return {} if text.strip.empty?

        parsed = JSON.parse(text)
        return parsed if parsed.is_a?(Hash)

        warn_arguments(name)
      rescue JSON::ParserError
        warn_arguments(name)
      end

      def warn_arguments(name)
        Log.warn(:model, "tool_arguments_invalid", tool: name, detail: "sent as {} to a Messages host")
        {}
      end

      def tool_result(message)
        block = { type: "tool_result", tool_use_id: tool_id(message[:tool_call_id]) }
        text = scrub(message[:content].to_s)
        block[:content] = text unless blank?(text)
        block
      end

      # A String or a parts list as blocks.
      def content_blocks(content)
        return blank?(content.to_s) ? [] : [text_block(scrub(content.to_s))] unless content.is_a?(Array)

        content.filter_map do |raw|
          next unless raw.is_a?(Hash)

          part = raw.transform_keys(&:to_sym)
          case part[:type].to_s
          when "text" then blank?(part[:text].to_s) ? nil : text_block(scrub(part[:text].to_s))
          when "image_url" then image_block(part[:image_url])
          when "image" then raw
          end
        end
      end

      def image_block(image_url)
        url = image_url.is_a?(Hash) ? (image_url[:url] || image_url["url"]).to_s : image_url.to_s
        if (match = url.match(/\Adata:([^;,]+);base64,(.*)\z/m))
          { type: "image", source: { type: "base64", media_type: match[1], data: match[2] } }
        elsif url.match?(%r{\Ahttps?://}i)
          { type: "image", source: { type: "url", url: url } }
        end
      end

      # Breakpoint #2: the last user block that can carry one and didn't
      # come from a later system message (+notes+).
      def mark_last(messages, cache, notes)
        markable = ->(block) { !UNMARKABLE.include?(type_of(block)) && !notes.key?(block) }
        message = messages.reverse_each.find { |m| m[:role] == "user" && m[:content].any?(&markable) } or return
        index = message[:content].rindex(&markable)
        block = message[:content][index]
        key = block.key?("type") ? "cache_control" : :cache_control
        message[:content][index] = block.merge(key => cache)
      end

      def type_of(block) = (block[:type] || block["type"]).to_s

      def text_block(text) = { type: "text", text: text }

      def blank?(text) = text.strip.empty?

      def scrub(text) = Utf8Scrub.call(text)

      private_class_method :append, :system_blocks, :assistant_blocks, :input_of, :warn_arguments, :tool_result,
                           :content_blocks, :image_block, :mark_last, :valid_tool_use, :type_of, :text_block, :blank?, :scrub
    end
  end
end
