# frozen_string_literal: true

require_relative "model_profile"
require_relative "prompt_literal_guard"
require_relative "vision_context"
require_relative "tool_response"
require_relative "steer"

module Samagotchi
  # Formats a message list into a prompt string ready for the /completion endpoint.
  #
  # Supports multiple model profiles (Gemma 4, Qwen 3.6, etc.) with different
  # token formats, role prefixing strategies, and tool response handling.
  #
  # Gemma 4 (as its chat template renders a conversation):
  #   - Turn markers: <|turn>ROLE\n...<turn|>\n, the text trimmed
  #   - Tool calls and their responses stay inside the model's turn:
  #     ...<tool_call|><|tool_response>response:NAME{value:<|"|>...<|"|>}<tool_response|>
  #     and the model goes on in the same turn
  #   - Generation cue: <|turn>model\n, or nothing after a tool response
  #   - An answer's thought is dropped once a later user turn starts
  #
  # Qwen 3.6:
  #   - Role framing: <|im_start|>ROLE\n...<|im_end|>
  #   - Tool response: wrapped in user message with <tool_response>...</tool_response>
  #   - Generation cue: <|im_start|>assistant\n
  module Prompt
    # Tail system messages whose text isn't the harness's own.
    ESCAPED_KINDS = %w[note turn_note context].freeze

    # @param messages [Array<Hash>] each element has :role and :content.
    #   Recognised roles: "system", "user", "model", "tool_response".
    # @param profile [ModelProfile] model token configuration
    # @return [String] formatted prompt ready for the /completion endpoint.
    def self.format(messages, profile: ModelProfile.default)
      format_with_images(messages, profile: profile).first
    end

    # The prompt plus the base64 images it carries, in marker order. Each
    # image a message sends is a line after its text: "[image N: name] "
    # and the profile's image template around ImagePlan::NATIVE_PLACEHOLDER
    # (Client#complete swaps in the server's media marker); an image left
    # out is its placeholder line. With no images the prompt is exactly
    # what it was before images existed.
    #
    # @param vision [VisionContext, nil] the turn's images context
    # @param prefill [String] text after the generation cue, the start of
    #   the model's answer (Thinking.native: Qwen's empty thought)
    # @return [Array(String, Array<String>)]
    def self.format_with_images(messages, profile: ModelProfile.default, vision: nil, prefill: "")
      plan = ImagePlan.new(messages, vision, data: :base64)
      images = []
      suffixes = messages.each_with_index.map { |m, index| image_lines(plan.items(m, index), profile, images) }
      text = if profile.uses_role_prefixes?
               format_with_prefixes(messages, profile, suffixes)
             else
               format_with_turn_markers(messages, profile, suffixes)
             end
      [text + prefill_for(messages, profile, prefill), images]
    end

    # A message's image lines: +text+ holds them all in order (what goes
    # inside the message); +placeholders+ and +markers+ split the lines of
    # images not sent from the sent ones' media markers, for Gemma's tool
    # response, whose markers go after the block.
    ImageLines = Data.define(:lines) do
      def text = join(lines)
      def placeholders = join(lines.reject(&:last))
      def markers = join(lines.select(&:last))

      private

      def join(subset) = subset.empty? ? "" : "\n#{subset.map(&:first).join("\n")}"
    end

    def self.image_lines(items, profile, images)
      lines = items.each_with_index.map do |item, index|
        next [item.placeholder, false] unless item.sent?
        next [ImageRef.placeholder(item.ref, ImagePlan::CANT_SEE), false] unless profile.image_template

        images << item.data
        ["[image #{index + 1}: #{ImageRef.name(item.ref)}] " \
         "#{Kernel.format(profile.image_template, marker: ImagePlan::NATIVE_PLACEHOLDER)}", true]
      end
      ImageLines.new(lines: lines)
    end

    def self.format_with_turn_markers(messages, profile, suffixes)
      last_user = messages.rindex { |m| m[:role] == "user" } || -1
      parts = messages.each_with_index.map do |m, index|
        lines = suffixes[index]
        content = prompt_content_for(m, profile) + (m[:role] == "tool_response" ? lines.placeholders : lines.text)
        previous = index.positive? ? messages[index - 1][:role] : nil
        following = messages[index + 1]&.dig(:role)
        case m[:role]
        when "tool_response"
          # Inside the model's turn; closed when another role follows. Its
          # sent images go after the blocks, outside the quoted value, as
          # Gemma's chat template puts them; placeholder lines stay inside.
          tool_response_blocks(content, profile) + lines.markers +
            (following && following != "tool_response" && following != "model" ? "#{profile.turn_end}\n" : "")
        when "model"
          content = strip_gemma_thought(content) if index < last_user && !content.include?(profile.tool_call_open)
          opener = previous == "tool_response" ? "" : "#{profile.turn_start}model\n"
          closer = following == "tool_response" ? "" : "#{profile.turn_end}\n"
          "#{opener}#{content.strip}#{closer}"
        else
          "#{profile.turn_start}#{m[:role]}\n#{content.strip}#{profile.turn_end}\n"
        end
      end
      parts << "#{profile.turn_start}model\n" unless ends_in_tool_response?(messages)
      parts.join
    end

    def self.ends_in_tool_response?(messages)
      messages.last&.dig(:role) == "tool_response"
    end

    # The text after the generation cue: +prefill+, except where Gemma's
    # turn goes on after a tool response (no cue, so nothing to fill).
    # The prompt and the model message the kernel keeps both use it.
    def self.prefill_for(messages, profile, prefill)
      return "" if !profile.uses_role_prefixes? && ends_in_tool_response?(messages)

      prefill.to_s
    end

    # A native tool_response entry (ToolResponse.joined: "[name]" outputs
    # joined by its SEPARATOR) as Gemma's template writes the results: one
    # response:NAME{value:<|"|>…<|"|>} block per call (ToolResponse.split:
    # a part that doesn't open with a "[name]" is the previous output's own
    # text).
    def self.tool_response_blocks(content, profile)
      runs = ToolResponse.split(content).map { |run| [run.name || "unknown", run.body] }
      runs = [["unknown", ""]] if runs.empty?
      q = profile.string_delim
      runs.map do |name, body|
        "#{profile.tool_response_open}response:#{name}{value:#{q}#{body}#{q}}#{profile.tool_response_close}"
      end.join
    end

    GEMMA_THOUGHT_BLOCK = /#{Regexp.escape(ModelProfile::GEMMA_THOUGHT_CHANNEL_OPEN.delete_suffix("thought"))}.*?#{Regexp.escape(ModelProfile::GEMMA_THOUGHT_CHANNEL_CLOSE)}/m
    private_constant :GEMMA_THOUGHT_BLOCK

    def self.strip_gemma_thought(content)
      content.gsub(GEMMA_THOUGHT_BLOCK, "")
    end

    def self.format_with_prefixes(messages, profile, suffixes)
      # Qwen 3.6 style: <|im_start|>ROLE\n...<|im_end|>
      parts = []

      messages.each_with_index do |m, index|
        content = prompt_content_for(m, profile) + suffixes[index].text
        case m[:role]
        when "system"
          parts << "#{profile.system_prefix}#{content}<|im_end|>\n"
        when "user"
          parts << "#{profile.user_prefix}#{content}<|im_end|>\n"
        when "model"
          parts << "#{profile.model_prefix}#{content}<|im_end|>\n"
        when "tool_response"
          # Wrap tool response in user message for Qwen
          parts << "#{profile.user_prefix}#{profile.tool_response_open}\n#{content}#{profile.tool_response_close}\n<|im_end|>\n"
        end
      end

      # Cue generation as assistant
      parts << profile.assistant_prefix
      parts.join
    end

    def self.prompt_content_for(message, profile)
      return message[:content].to_s if message[:preserve_literals]

      # A context note is system-framed but its text is untrusted (Slack, a
      # peer session), and a turn note carries an error's text: escaped like
      # user content so it can't close its turn.
      role = ESCAPED_KINDS.include?(message[:kind].to_s) ? "user" : message[:role]
      # A steer or merged input is led by a header naming its sender (added
      # after the escape: the header has no literals to guard).
      Steer.wire_text(message, PromptLiteralGuard.escape(message[:content], profile: profile, role: role))
    end

    private_class_method :image_lines, :format_with_turn_markers, :ends_in_tool_response?, :tool_response_blocks,
                         :strip_gemma_thought, :format_with_prefixes, :prompt_content_for
  end
end
