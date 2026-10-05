# frozen_string_literal: true

require_relative "config"
require_relative "log"

module Samagotchi
  # The turn-end warm-up (cache.warmup). After a turn, the next turn's prompt
  # differs from the last request at its tail: the previous answer's
  # thinking is stripped (Gemma's and Qwen's specs), so a hybrid model on
  # llama.cpp prefills from a restore point well before the end, longer
  # with every turn. The warm-up sends that prompt, up to where the new user
  # turn starts, while the user reads, so the next turn prefills only its
  # own message (measured on Ornith: 0.73 s -> 0.11 s; 417 -> 26 tokens).
  #
  # The slot rule (R4 spike, llama.cpp with its host-memory prompt cache):
  # - the warm-up runs on the slot the turn's last request used, which still
  #   holds its state (Client#warm_up, `id_slot`);
  # - the next request is pinned to that slot only while the warm-up still
  #   runs, so it queues behind it (0.6 s) instead of starting cold on
  #   another slot (12 s);
  # - once the warm-up is done, nothing is pinned: the server finds the
  #   state itself, and pinning to a slot it has since cleared skips its
  #   prompt cache (12 s again). #take_pin forgets the slot either way;
  # - no warm-up when /slots says that slot is busy (Client#slot_status):
  #   another session took it (a delegate child, often), and llama.cpp
  #   defers a pinned request until the slot is free, so the warm-up and
  #   then this session's next turn would wait out that generation. The
  #   next request then goes unpinned, and the server's prompt cache
  #   restores the state. When /slots can't say, the warm-up runs.
  class PromptWarmup
    MODES = %w[auto off].freeze
    # Seconds #take_pin waits for the busy-slot check (Client#slot_status
    # gives up within 3 s).
    DECIDE_TIMEOUT = 3

    # Whether cache.warmup allows a warm-up (auto, the default; off, false,
    # no or 0 turn it off; anything else warns once and is auto).
    def self.enabled?
      value = Config.get("cache.warmup").to_s.strip.downcase
      return false if %w[off false no 0].include?(value)

      unless value.empty? || value == "auto" || @warned
        @warned = true
        Log.warn(:config, "invalid_value", echo: "Warning: invalid value for cache.warmup: #{value.inspect} (allowed: auto, off) — using auto",
                                           key: "cache.warmup")
      end
      true
    rescue StandardError
      true
    end

    def initialize
      @mutex = Mutex.new
      # The pin (#take_pin forgets it) and the last warm-up's thread.
      @state = nil
      @thread = nil
    end

    # Start a warm-up of +prompt+ on +client+ in its own thread.
    # @param slot [Integer, nil] the last request's slot (nil: unpinned, and
    #   nothing to pin the next request to)
    # @return [Thread]
    def start(client:, prompt:, model:, slot:, images: [])
      # Whether the warm-up went to its slot (true) or was skipped: the
      # first value pushed is the answer.
      sent = Queue.new
      thread = Thread.new do
        Thread.current.report_on_exception = false
        busy = slot.is_a?(Integer) && client.slot_status(slot, model: model) == :busy
        sent << !busy
        next skip(slot) if busy

        result = client.warm_up(prompt, model: model, slot: slot, images: images)
        Log.info(:model, "warmup", slot: result&.slot, cached: result&.cache_n, prefilled: result&.prompt_n,
                                   prefill_ms: result&.prompt_ms, chars: prompt.length)
        result
      rescue StandardError => e
        Log.warn(:model, "warmup_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        nil
      ensure
        sent << false
      end
      @mutex.synchronize do
        @thread = thread
        @state = { thread: thread, client: client, slot: slot, sent: sent }
      end
      thread
    end

    # The slot the next request on +client+ must run on: the warm-up's,
    # while it still runs there; nil otherwise (done, failed, skipped,
    # unpinned, or another host). Called once per request; the first call
    # forgets the warm-up, so no later request is ever pinned. Waits for
    # the busy-slot check (DECIDE_TIMEOUT at most).
    def take_pin(client)
      state = @mutex.synchronize { @state.tap { @state = nil } }
      return nil unless state && state[:slot].is_a?(Integer) && state[:client].equal?(client)
      return nil unless state[:sent].pop(timeout: DECIDE_TIMEOUT)

      state[:thread].alive? ? state[:slot] : nil
    end

    private def skip(slot)
      Log.info(:model, "warmup_skipped", slot: slot, why: "slot busy")
      nil
    end

    # Whether a warm-up is running (specs, measurements).
    def running?
      thread = @mutex.synchronize { @thread }
      thread&.alive? || false
    end

    # Wait up to +timeout+ seconds for the running warm-up (specs).
    def wait(timeout = nil)
      thread = @mutex.synchronize { @thread }
      thread&.join(timeout)
    end
  end
end
