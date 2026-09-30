# frozen_string_literal: true

module Samagotchi
  # A plugin's steer: text a plugin puts into the running turn (Engine#steer),
  # the way a UI's steering does. The drain a loop gets returns items: a
  # String (a user line, as ever) or {text:, source:} (a steer). The user
  # lines merge into one user message as before; each steer follows it as its
  # own user message marked kind: "steer" and source: (the ContextNote keys,
  # which every message copy keeps). The model reads it as user text.
  #
  # The user's own lines merged into a running turn are marked kind:
  # "input": they are part of that turn, not a turn of their own, so a
  # reloaded history keeps the turn in one piece.
  module Steer
    KIND = "steer"
    INPUT_KIND = "input"

    # What one drain brought: the merged user text (nil when none) and how
    # many lines made it, and the steers in order.
    Merge = Struct.new(:content, :count, :steers, keyword_init: true) do
      def empty? = content.nil? && steers.empty?

      # The messages it appends: the user's first (marked merged input),
      # then each steer.
      def messages
        list = content ? [{ role: "user", kind: INPUT_KIND, content: content }] : []
        list + steers.map { |steer| Steer.message(**steer) }
      end

      # The :pending_input_merged fields beside iteration and answer;
      # steers: only when there are some, so plain merges stay as they were.
      def event_fields
        fields = { count: count, content: content }
        fields[:steers] = steers unless steers.empty?
        fields
      end
    end

    module_function

    def message(text:, source:)
      { role: "user", kind: KIND, source: source.to_s, content: text.to_s }
    end

    def steer?(message)
      (message[:kind] || message["kind"]).to_s == KIND
    end

    # A user message that is a prompt or the user's steering, not a steer:
    # what "the last prompt" and "user turns" count.
    def prompt?(message)
      message.is_a?(Hash) && (message[:role] || message["role"]).to_s == "user" && !steer?(message)
    end

    # The user's lines merged into a running turn (Merge#messages).
    def input?(message)
      message.is_a?(Hash) && (message[:kind] || message["kind"]).to_s == INPUT_KIND
    end

    # A prompt that started a turn: not a steer, not input merged into a
    # running turn. What the turns a page shows count.
    def turn_prompt?(message)
      prompt?(message) && !input?(message)
    end

    # Call a loop's drain: +at_answer+ goes only to a drain that takes it
    # (the Engine's); a caller's own drain (a queue's #drain) is called bare.
    # A failing drain drains nothing (the loop keeps going).
    def drain(pending_input, at_answer:)
      takes = pending_input.respond_to?(:parameters) &&
              pending_input.parameters.any? { |type, name| %i[key keyreq].include?(type) && name == :at_answer }
      takes ? pending_input.call(at_answer: at_answer) : pending_input.call
    rescue StandardError
      nil
    end

    # @return [Merge]
    def merge(items)
      items = Array(items)
      lines = items.grep_v(Hash)
      steers = items.grep(Hash).filter_map do |item|
        text = (item[:text] || item["text"]).to_s.strip
        { source: (item[:source] || item["source"]).to_s, text: text } unless text.empty?
      end
      content = lines.map { |line| line.to_s.strip }.reject(&:empty?).join("\n\n")
      Merge.new(content: content.empty? ? nil : content, count: content.empty? ? 0 : lines.length, steers: steers)
    end
  end
end
