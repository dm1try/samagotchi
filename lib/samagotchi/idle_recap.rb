# frozen_string_literal: true

require "json"
require "monitor"
require "time"

require_relative "idle_client"
require_relative "output_formatter"

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
    WAIT_TICK_SECONDS = 0.1
    # Above this many tool calls we ask only for a goal/achievement summary
    # (never enumerate calls).
    LARGE_TOOL_THRESHOLD = 10

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
      # separator, while the ruby_llm backend writes one message per call.
      TOOL_OUTPUT_SEPARATOR = "\n\n---\n\n"
      TOOL_OUTPUT_HEADER_RE = /\A\[([\w.:-]+)\]/

      module_function

      def build(messages)
        Array(messages).filter_map do |message|
          next unless message.is_a?(Hash)

          case message["role"]
          when "user"
            message["content"].to_s
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

      def strip_thought(text)
        OutputFormatter.strip(IdleClient.strip_thinking(text))
      end
    end

    # Builds the recap prompt. Short (2-4 sentences). Names the handful of tool
    # calls briefly when the count is small; states only the count + overall
    # goal when the count is large (never enumerates).
    module RecapPrompt
      module_function

      # @return [String, nil] nil when there is no transcript to summarize
      def build(transcript, tool_count: nil, tool_names: [])
        body = transcript.to_s.strip
        return nil if body.empty?

        tool_count ||= tool_names.size
        if tool_count > LARGE_TOOL_THRESHOLD
          <<~PROMPT.strip
            The user and assistant worked together for a session. Below is the
            cleaned transcript (the system prompt and tool internals were removed;
            only user turns and assistant prose remain). A total of #{tool_count}
            tool calls were made#{tools_used(tool_names)} — DO NOT enumerate them. Instead write a short
            (2-4 sentence) recap covering: the overall goal, what was completed,
            any key facts or project props the user mentioned, and anything still
            pending.
            ---
            #{body}
          PROMPT
        else
          count_word = tool_count == 1 ? "1 tool call" : "#{tool_count} tool calls"
          <<~PROMPT.strip
            The user and assistant worked together for a session. Below is the
            cleaned transcript (the system prompt and tool internals were removed;
            only user turns and assistant prose remain). About #{count_word}#{tools_used(tool_names)}
            were made. Write a short (2-4 sentence) recap covering: the overall
            goal, what was completed, any key facts or project props the user
            mentioned, and anything still pending. You may briefly name the
            handful of tool calls that were central to the work.
            ---
            #{body}
          PROMPT
        end
      end

      # " (execute x3, read_file)", or "" when no names are known
      def tools_used(names)
        return "" if names.empty?

        " (#{names.tally.map { |name, n| n > 1 ? "#{name} x#{n}" : name }.join(', ')})"
      end
    end

    attr_reader :generation, :inactivity, :min_user_turns

    def initialize(engine:, model:, base_url:,
                   inactivity: DEFAULT_INACTIVITY_SECONDS,
                   min_user_turns: DEFAULT_MIN_USER_TURNS,
                   timeout: DEFAULT_TIMEOUT_SECONDS,
                   client: nil,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      raise ArgumentError, "IdleRecap requires an engine" unless engine

      @engine = engine
      @model = model
      @base_url = base_url
      @inactivity = inactivity
      @min_user_turns = min_user_turns
      @timeout = timeout
      @client = client || IdleClient.new(model: model, base_url: base_url, timeout: timeout)
      @clock = clock

      @mutex = Monitor.new
      @generation = 0
      @last_fire_activity_seq = nil
    end

    # Mark any in-flight recap stale (called when a new turn starts). The
    # generation id bumps so the summarizing worker sees the mismatch and drops
    # its result instead of rendering a recap for a turn that is now running.
    def invalidate!
      @mutex.synchronize { @generation += 1 }
    end

    # One detector step, called by the shared IdleScheduler. Public so specs
    # can drive it deterministically.
    def tick
      return unless should_fire?

      generate
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

    def generate
      gen = bump_generation
      # Latch the attempt, not the success: a short history, a failed or
      # empty summary, or an invalidated run must not re-fire on every
      # scheduler tick. The next recorded activity re-arms the window.
      @last_fire_activity_seq = @engine.activity_seq
      snapshot = @engine.messages_json_for_recap
      parsed = safe_parse(snapshot)
      return if parsed.nil? || parsed.empty?
      user_turns = parsed.count { |message| message.is_a?(Hash) && message["role"] == "user" }
      return if user_turns < @min_user_turns
      transcript = TranscriptFilter.build(parsed)
      prompt = RecapPrompt.build(transcript, tool_names: TranscriptFilter.tool_names(parsed))
      return if prompt.nil?
      worker = spawn_summarize(prompt)
      return unless wait_until_finished(worker, gen)
      return unless valid_generation?(gen)
      recap = safe_value(worker)
      return if recap.nil? || recap.to_s.strip.empty?
      @engine.emit_recap(recap: recap.to_s, generation: gen)
    rescue StandardError
      nil
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

    def wait_until_finished(worker, gen)
      deadline = @clock.call + @timeout
      until !worker.alive? || !valid_generation?(gen) || @clock.call >= deadline
        sleep(WAIT_TICK_SECONDS)
      end
      # Return true only if worker finished AND generation is still valid
      !worker.alive? && valid_generation?(gen)
    end
  end
end
