# frozen_string_literal: true

require_relative "model_profile"
require_relative "prompt_literal_guard"
require_relative "vision_context"

module Samagotchi
  # Formats a message list into a prompt string ready for the /completion endpoint.
  #
  # Supports multiple model profiles (Gemma 4, Qwen 3.6, etc.) with different
  # token formats, role prefixing strategies, and tool response handling.
  #
  # Gemma 4:
  #   - Turn markers: <|turn>ROLE\n...<end_of_turn>\n
  #   - Tool response: standalone <|tool_response>...<tool_response|>
  #   - Generation cue: <|turn>model\n
  #
  # Qwen 3.6:
  #   - Role framing: <|im_start|>ROLE\n...<|im_end|>
  #   - Tool response: wrapped in user message with <tool_response>...</tool_response>
  #   - Generation cue: <|im_start|>assistant\n
  module Prompt
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
    # @return [Array(String, Array<String>)]
    def self.format_with_images(messages, profile: ModelProfile.default, vision: nil)
      plan = ImagePlan.new(messages, vision, data: :base64)
      images = []
      suffixes = messages.each_with_index.map { |m, index| image_lines(plan.items(m, index), profile, images) }
      text = if profile.uses_role_prefixes?
               format_with_prefixes(messages, profile, suffixes)
             else
               format_with_turn_markers(messages, profile, suffixes)
             end
      [text, images]
    end

    private

    def self.image_lines(items, profile, images)
      return "" if items.empty?

      lines = items.each_with_index.map do |item, index|
        next item.placeholder unless item.sent?
        next ImageRef.placeholder(item.ref, ImagePlan::CANT_SEE) unless profile.image_template

        images << item.data
        "[image #{index + 1}: #{ImageRef.name(item.ref)}] " \
          "#{Kernel.format(profile.image_template, marker: ImagePlan::NATIVE_PLACEHOLDER)}"
      end
      "\n#{lines.join("\n")}"
    end

    def self.format_with_turn_markers(messages, profile, suffixes)
      # Gemma 4 style: <|turn>ROLE\n...<end_of_turn>\n
      parts = messages.each_with_index.map do |m, index|
        content = prompt_content_for(m, profile) + suffixes[index]
        if m[:role] == "tool_response"
          "#{profile.tool_response_open}\n#{content}#{profile.tool_response_close}\n"
        else
          "#{profile.turn_start}#{m[:role]}\n#{content}#{profile.turn_end}\n"
        end
      end
      parts << "#{profile.turn_start}model\n"
      parts.join
    end

    def self.format_with_prefixes(messages, profile, suffixes)
      # Qwen 3.6 style: <|im_start|>ROLE\n...<|im_end|>
      parts = []

      messages.each_with_index do |m, index|
        content = prompt_content_for(m, profile) + suffixes[index]
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
      # peer session): escaped like user content so it can't close its turn.
      role = message[:kind].to_s == "note" ? "user" : message[:role]
      PromptLiteralGuard.escape(message[:content], profile: profile, role: role)
    end
  end
end
