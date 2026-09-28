# frozen_string_literal: true

require_relative "log"

module Samagotchi
  # How a turn's answer is shown, apart from what the model said: an
  # after_turn hook (or a plugin's on(:after_turn)) calls event[:present]
  # with a block that gets the current display text and returns the new
  # one. The result is kept as `display` on the answer's model message in
  # session.json; the web renders it instead of `content`. It is display
  # only: nothing that talks to a model reads it (the payload builders take
  # the fields they send, and the copies handed to hooks, plugins and the
  # recap leave it out, see .strip).
  #
  # The target is the stored conversation's last message when it is the
  # model's answer; a turn that ended any other way (cancelled, failed,
  # empty: a turn note is last) has none and event[:present] does nothing.
  class AnswerDisplay
    KEY = :display
    # A display text longer than this is refused (the display stays as it
    # was): a hook must not bloat session.json or the page.
    MAX_CHARS = 200_000

    # A message as a model-facing reader may see it: without `display`.
    # The same object when it has none.
    def self.strip(message)
      return message unless message.is_a?(Hash) && (message.key?(KEY) || message.key?(KEY.to_s))

      message.reject { |key, _| key.to_s == KEY.to_s }
    end

    def self.strip_all(messages)
      Array(messages).map { |message| strip(message) }
    end

    # @return [Hash, nil] the message event[:present] changes
    attr_reader :target
    # @return [String, nil] the display text so far
    attr_reader :text

    # @param messages [Array<Hash>] the conversation the turn stored
    def initialize(messages)
      last = Array(messages).last
      @target = last if last.is_a?(Hash) && field(last, :role).to_s == "model"
      @original = @target && (field(@target, KEY) || field(@target, :content)).to_s
      @text = @original
    end

    # True when a hook set a display text other than what was shown before.
    def changed?
      !@target.nil? && @text != @original
    end

    # event[:present]: call it with a block; the block gets the current
    # display text (the answer's content until a hook changed it) and
    # returns the new one. A block that raises, returns something other than
    # a String, or returns more than MAX_CHARS leaves the text unchanged
    # (logged, named by event[:hook]).
    # @param event [Hash] the after_turn event (for its :hook label)
    # @return [Proc] returns the display text after the call, or nil when
    #   the turn has no answer to present
    def presenter(event)
      lambda do |&block|
        next nil unless @target
        next @text unless block

        apply(block, event[:hook])
      end
    end

    private

    def apply(block, hook)
      value = begin
        block.call(@text.dup)
      rescue StandardError => e
        return reject(hook, "raised #{e.class}: #{e.message}")
      end
      return reject(hook, "returned #{value.class}, not a String") unless value.is_a?(String)
      return reject(hook, "returned #{value.length} characters (max #{MAX_CHARS})") if value.length > MAX_CHARS

      @text = value.dup
    end

    def reject(hook, why)
      Log.warn(:hooks, "present_rejected", echo: "[samagotchi:hooks] #{hook}: present #{why}; display unchanged",
                                           hook: hook.to_s)
      @text
    end

    def field(message, key)
      message.key?(key) ? message[key] : message[key.to_s]
    end
  end
end
