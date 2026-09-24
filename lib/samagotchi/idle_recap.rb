# frozen_string_literal: true

require "digest"
require "json"
require "monitor"
require "time"

require_relative "idle_client"
require_relative "output_formatter"
require_relative "recap_store"

module Samagotchi
  # Idle job for the session-recap feature — polled by the shared
  # IdleScheduler (one background thread for the whole idle layer).
  #
  # Owns the inactivity clock bookkeeping shared across UIs: it reads the
  # Engine's `last_activity_at` / `activity_seq` / `turn_running?` seam (the
  # single source of truth) rather than tracking its own timeline, so the
  # clock behaves identically for the interactive REPL and any Engine-backed
  # worker.
  #
  # When the session has been idle for `@inactivity` seconds, no turn is
  # running, and there are >= `@min_user_turns` user turns, the job
  # snapshots the conversation (as a JSON string, never mutating it), summarizes
  # it with a decoupled #IdleClient on a background thread, and emits a
  # `:recap_ready` event (with a generation id so an invalidated recap can't
  # render). Failures (server down, timeout, short history) are isolated and
  # never break the active session.
  class IdleRecap
    DEFAULT_INACTIVITY_SECONDS = 180.0
    DEFAULT_TIMEOUT_SECONDS = 30.0
    DEFAULT_MIN_USER_TURNS = 2
    # Above this many tool calls we ask only for a goal/achievement summary
    # (never enumerate calls).
    LARGE_TOOL_THRESHOLD = 10
    # The most new transcript one attempt sends (the tail is kept): a first
    # recap of a long session, or a long stretch since the last one.
    MAX_NEW_CHARS = 16_000

    # Build a cleaned recap transcript + the prompt text from a JSON snapshot.
    # Drops the system prompt and tool internals (call markup with its
    # arguments, tool outputs), keeps user turns and model prose (thoughts
    # stripped), and collects the tool names for the prompt.
    module TranscriptFilter
      # A tool call as the model wrote it inline: gemma, qwen, or the qwen
      # prompt-literal form. An unterminated gemma call runs to the end.
      TOOL_CALL_RE = /<\|tool_call>(?:.*?<tool_call\|>|.*\z)|<tool_call>.*?<\/tool_call>|\[\[SAMAGOTCHI_LITERAL_TOOL_CALL_OPEN\]\].*?\[\[SAMAGOTCHI_LITERAL_TOOL_CALL_CLOSE\]\]/m
      # Each dispatched call's output starts with "[name]"; the kernel loop
      # joins one step's outputs into a single tool_response with this
      # separator, while the chat loop writes one message per call.
      TOOL_OUTPUT_SEPARATOR = "\n\n---\n\n"
      TOOL_OUTPUT_HEADER_RE = /\A\[([\w.:-]+)\]/

      module_function

      def build(messages)
        Array(messages).filter_map do |message|
          next unless message.is_a?(Hash)

          case message["role"]
          when "user"
            # An image is a line naming it (refs only, never its bytes).
            [message["content"].to_s, *image_lines(message["images"])].reject(&:empty?).join("\n")
          when "model", "assistant"
            strip_thought(message["content"].to_s.gsub(TOOL_CALL_RE, ""))
          else
            # Drop system prompt + tool_response contents + anything else.
            nil
          end
        end.reject { |line| line.to_s.strip.empty? }.join("\n\n")
      end

      # @return [Array<String>] one tool name per dispatched call, in order
      def tool_names(messages)
        Array(messages).flat_map do |message|
          next [] unless message.is_a?(Hash) && message["role"] == "tool_response"

          message["content"].to_s.split(TOOL_OUTPUT_SEPARATOR).filter_map do |chunk|
            chunk[TOOL_OUTPUT_HEADER_RE, 1]
          end
        end
      end

      def image_lines(images)
        Array(images).filter_map { |ref| "[image #{ref["name"] || File.basename(ref["file"].to_s)}]" if ref.is_a?(Hash) }
      end

      def strip_thought(text)
        OutputFormatter.strip(IdleClient.strip_thinking(text))
      end
    end

    # Builds the recap prompt: the instructions as a system message and the
    # transcript as the user message (R0 spike: with one user message Ornith
    # opened 3/12 recaps with notes about the task; 0/12 this way). Short (2-4
    # sentences). Names the handful of tool calls briefly when the count is
    # small; states only the count when it is large (never enumerates). With
    # a previous recap it asks for an updated recap of the whole session from
    # that recap plus the transcript since.
    module RecapPrompt
      SYSTEM = "You write short recaps of a chat between a user and an assistant, for the user " \
               "coming back to it later. Reply with the recap only: 2-4 plain sentences, no heading, " \
               "no preamble, no notes about the task. Say \"the user\" and \"the assistant\". Cover " \
               "the overall goal, what was completed, any key facts or project props the user " \
               "mentioned, and anything still pending."
      # "do not just repeat": otherwise Ornith returned the earlier recap
      # word for word after a short turn.
      UPDATE = " You are given the earlier recap and the conversation since the earlier recap: " \
               "write an updated recap of the whole session that also covers what happened since " \
               "(do not just repeat the earlier recap)."
      OMITTED = "(earlier part omitted)"

      module_function

      # @return [Array<Hash>, nil] chat messages; nil when there is no
      #   transcript to summarize
      def build(transcript, tool_count: nil, tool_names: [], previous: nil)
        body = cap(transcript.to_s.strip)
        return nil if body.empty?

        tool_count ||= tool_names.size
        count_word = tool_count == 1 ? "1 tool call" : "#{tool_count} tool calls"
        tools = if tool_count > LARGE_TOOL_THRESHOLD
                  " #{count_word}#{tools_used(tool_names)} were made. Do not enumerate the tool calls."
                elsif tool_count.positive?
                  " About #{count_word}#{tools_used(tool_names)} were made; you may briefly name the " \
                    "handful of tool calls that were central to the work."
                else
                  ""
                end
        system = SYSTEM + (previous ? UPDATE : "") + tools
        user = +""
        user << "Earlier recap:\n#{previous}\n\n" if previous
        user << "Transcript#{previous ? ' since the earlier recap' : ''} (the system prompt and tool " \
                "internals were removed; only user turns and assistant prose remain):\n---\n#{body}\n---\n" \
                "Write the recap now."
        [{ role: "system", content: system }, { role: "user", content: user }]
      end

      # The tail of +body+ when it is over MAX_NEW_CHARS, from a paragraph
      # start when one is near, after an "(earlier part omitted)" line.
      def cap(body)
        return body if body.size <= MAX_NEW_CHARS

        tail = body[-MAX_NEW_CHARS..]
        cut = tail.index("\n\n")
        tail = tail[(cut + 2)..] if cut && cut < 2_000
        "#{OMITTED}\n\n#{tail}"
      end

      # " (execute x3, read_file)", or "" when no names are known
      def tools_used(names)
        return "" if names.empty?

        " (#{names.tally.map { |name, n| n > 1 ? "#{name} x#{n}" : name }.join(', ')})"
      end
    end

    attr_reader :generation, :inactivity, :min_user_turns

    # @return [Hash, nil] the last recap written: {text:, covered:,
    #   covered_digest:, model:, created_at:}, where covered counts the
    #   session messages it summarizes and covered_digest fingerprints the
    #   last of them. With a store, loaded from it for each new session.
    def state
      @mutex.synchronize do
        if @store && @store_key != (key = @store.key)
          @store_key = key
          @state = @store.load
        end
        @state&.dup
      end
    end

    # @param base_url [String] the OpenAI API base the recap asks
    # @param api_key_env [String, nil] the variable holding its key
    def initialize(engine:, model:, base_url:, api_key_env: nil,
                   inactivity: DEFAULT_INACTIVITY_SECONDS,
                   min_user_turns: DEFAULT_MIN_USER_TURNS,
                   timeout: DEFAULT_TIMEOUT_SECONDS,
                   client: nil,
                   store: nil,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      raise ArgumentError, "IdleRecap requires an engine" unless engine

      @engine = engine
      @model = model
      @base_url = base_url
      @inactivity = inactivity
      @min_user_turns = min_user_turns
      @timeout = timeout
      @client = client || IdleClient.new(model: model, base_url: base_url, api_key_env: api_key_env, timeout: timeout)
      @clock = clock
      @store = store

      @mutex = Monitor.new
      @generation = 0
      @last_fire_activity_seq = nil
      @in_flight = nil
      @state = nil
    end

    # Mark any in-flight recap stale (called when a new turn starts). The
    # generation id bumps so the summarizing worker sees the mismatch and drops
    # its result instead of rendering a recap for a turn that is now running.
    def invalidate!
      @mutex.synchronize { @generation += 1 }
    end

    # One detector step, called by the shared IdleScheduler. Public so specs
    # can drive it deterministically. Never waits on the summarizer: it
    # collects a finished (or overdue) request, else starts one when
    # eligible, so the other idle jobs keep ticking meanwhile.
    def tick
      return collect if in_flight?
      return unless should_fire?

      start
    end

    # @return [Boolean] true while a summarize request is running
    def in_flight?
      !@in_flight.nil?
    end

    # @return [Boolean] true when a recap is eligible to fire right now.
    def should_fire?
      return false if @engine.turn_running?
      return false unless last_idle_seconds >= @inactivity
      # Fire at most once per idle window: require that activity advanced the
      # shared seq since the last fire. Pure monotonic time passing does NOT
      # bump the seq, so a long idle window only summarizes once.
      return true if @last_fire_activity_seq.nil?

      @engine.activity_seq > @last_fire_activity_seq
    end

    private

    def last_idle_seconds
      @clock.call - @engine.last_activity_at
    end

    # Start an attempt: snapshot, build the prompt, and spawn the summarize
    # thread. The result is picked up by #collect on a later tick.
    def start
      gen = bump_generation
      # Latch the attempt, not the success: a short history, a failed or
      # empty summary, or an invalidated run must not re-fire on every
      # scheduler tick. The next recorded activity re-arms the window.
      @last_fire_activity_seq = @engine.activity_seq
      parsed = safe_parse(@engine.messages_json_for_recap)
      return if parsed.nil? || parsed.empty?
      user_turns = parsed.count { |message| message.is_a?(Hash) && message["role"] == "user" }
      return if user_turns < @min_user_turns
      previous = continuable_state(parsed)
      fresh = parsed.drop(previous ? previous[:covered] : 0)
      transcript = TranscriptFilter.build(fresh)
      # Nothing new said (only notes, tool traffic, or no messages at all):
      # the recap still stands, so no request.
      return if transcript.strip.empty?
      prompt = RecapPrompt.build(transcript, tool_names: TranscriptFilter.tool_names(fresh), previous: previous&.dig(:text))
      return if prompt.nil?
      @in_flight = { thread: spawn_summarize(prompt), generation: gen, deadline: @clock.call + @timeout,
                     covered: parsed.size, covered_digest: self.class.digest(parsed.last) }
    rescue StandardError
      nil
    end

    # Pick up the in-flight attempt. Save/emit happens only here, on the
    # scheduler thread, never from the summarize thread: a stale (turn
    # started) or overdue attempt is dropped. An overdue thread is left to
    # its IdleClient timeout (the same budget), not killed mid-request.
    def collect
      job = @in_flight
      unless valid_generation?(job[:generation])
        @in_flight = nil
        return
      end
      if job[:thread].alive?
        @in_flight = nil if @clock.call >= job[:deadline]
        return
      end
      @in_flight = nil
      recap = safe_value(job[:thread])
      return if recap.nil? || recap.to_s.strip.empty?
      saved = { text: recap.to_s, covered: job[:covered], covered_digest: job[:covered_digest],
                model: @model, created_at: Time.now.utc.iso8601 }
      @mutex.synchronize { @state = saved }
      save(saved)
      @engine.emit_recap(recap: recap.to_s, generation: job[:generation], covered: job[:covered])
    rescue StandardError
      @in_flight = nil
    end

    def save(state)
      @store&.save(state)
    rescue StandardError => e
      warn "[IdleRecap] saving the recap failed: #{e.class}: #{e.message}"
    end

    # The saved state when it still describes a prefix of +messages+; nil
    # (start over) when the history got shorter or was rewritten (a
    # rollback, a cancelled or failed turn replaced).
    def continuable_state(messages)
      saved = state
      return nil unless saved && saved[:covered].to_i.positive?
      return nil if saved[:covered] > messages.size
      return nil unless self.class.digest(messages[saved[:covered] - 1]) == saved[:covered_digest]

      saved
    end

    # SHA1 of one message's role and text: detects a rewrite a count alone
    # misses. Model text is taken without its thinking, which is dropped from
    # older model messages when the next turn starts.
    def self.digest(message)
      return nil unless message.is_a?(Hash)

      text = message["content"].to_s
      text = TranscriptFilter.strip_thought(text) if %w[model assistant].include?(message["role"])
      Digest::SHA1.hexdigest("#{message['role']}\0#{text}")
    end

    def bump_generation
      @mutex.synchronize { @generation += 1 }
    end

    def valid_generation?(gen)
      @mutex.synchronize { @generation == gen }
    end

    def spawn_summarize(prompt)
      Thread.new do
        @client.summarize(prompt)
      rescue StandardError
        nil
      end
    end

    def safe_value(worker)
      worker.value
    rescue StandardError
      nil
    end

    def safe_parse(json)
      JSON.parse(json)
    rescue StandardError
      []
    end
  end
end
