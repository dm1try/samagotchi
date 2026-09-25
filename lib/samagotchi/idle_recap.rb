# frozen_string_literal: true

require "digest"
require "json"
require "monitor"
require "time"

require_relative "idle_client"
require_relative "output_formatter"
require_relative "recap_store"
require_relative "log"

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
    # sentences) and centred on outcomes: the task, what came of it, what is
    # open. Passive voice — no actors at all (voice spike 2026-09-25: the
    # 3rd-person "the user was…/the assistant…" projection read as a third
    # party watching; "we" was consistent but the user preferred outcomes
    # without persons; the small model occasionally drifts back to naming
    # actors, which is tolerated). Names the handful of tool calls only when
    # they matter to the result; states only the count when it is large (never
    # enumerates). With a previous recap it asks for an updated recap of the
    # whole session from that recap plus the transcript since.
    module RecapPrompt
      # Recap-length S0 spike (Ornith 35B-A3B, 4 sessions): without the
      # example opening, first recaps still began "The user asked the
      # assistant to…" (goal first 25% → 100% with it); without "never by
      # name" it wrote "Dmitry and Chi"; without the side-details list it
      # kept the user's city and repo count, and paths and versions.
      # Recap-polish spike (same 4 sessions): without the "lacks" line 4/20
      # first recaps at 2-4 said "…weren't captured in the transcript"; 0/80
      # with it. (A "short sentences, no dashes" line was dropped: with this
      # one it brought back "Chi" as an actor in 15-18/80.)
      # Voice spike (same 4 sessions, 2026-09-25): the passive "no actors"
      # rule reads like a personal changelog ("Explored… then implemented…");
      # it drifted to "the user and assistant" on 1/4 (a session with clear
      # user decisions) — tolerated. The "we" variant was 4/4 consistent.
      # %<plain>s is the range, e.g. "2-4 plain sentences"; %<shape>s is SHAPE
      # or ONE_SHAPE.
      SYSTEM = "You write short recaps of a chat between a user and an assistant, for the user " \
               "coming back to it later. Reply with the recap only: %<plain>s, no heading, " \
               "no preamble, no notes about the task or the transcript. Do not mention what the " \
               "transcript lacks or does not say; leave it out. Centre it on outcomes, not on " \
               "the order of events. %<shape>s Keep project names " \
               "and facts that matter for continuing. Do not retell the chat turn by turn (\"the user " \
               "asked..., then the assistant...\"). Never name who did something: no \"the user\", no " \
               "\"the assistant\", no \"I\", no \"we\", no personal names — state outcomes and decisions " \
               "without actors (\"a 28-day threshold was chosen\", \"the plan was saved\"). Leave out " \
               "side details: personal " \
               "details about the user (where they live, their accounts, how many repos they have), " \
               "file paths and version numbers, unless they are the point. If there was no clear task, " \
               "just say what was talked about."
      SHAPE = "The first sentence names the task itself (\"Checking how the parser handles tabs\"), " \
              "not who asked for it. Then say what came of it: results, decisions, findings. End with " \
              "what is still open or the next step, if anything."
      # recap.sentences: 1. Asking for "1 plain sentence" next to SHAPE's
      # first sentence, then results, then what is open gave 3.4 sentences
      # (1 exactly in 0/20, spike); with this shape 1 in 40/40, goal first.
      ONE_SHAPE = "The sentence names the task itself (\"Checking how the parser handles tabs\"), not " \
                  "who asked for it, and where it stands: the result, or what is still open."
      # "do not just repeat": otherwise Ornith returned the earlier recap
      # word for word after a short turn.
      UPDATE = " You are given the earlier recap and the conversation since the earlier recap: " \
               "write an updated recap of the whole session that also covers what happened since " \
               "(do not just repeat the earlier recap)."
      # Holds the length once the recap covers more (S0: an updated recap ran
      # to 6 sentences for 2-4 without it, within range+1 in 95%+ with it).
      # The first-sentence line keeps the list preview on the task.
      UPDATE_LENGTH = " Keep it to %<sentences>s even though it now covers more: merge or drop older " \
                      "details rather than adding sentences. Keep %<focus>s on the task (change it " \
                      "if the focus moved)."
      # At an open continue offer (the last turn ran out of steps with a
      # tool call pending). Recap-next F1 spike: without it the recap stated
      # the stop in 5-10% and said "no open items" 7/40; with this line
      # after the transcript 95-100% and 0. A system sentence as well made
      # it worse (a chit-chat session judged there was no task). Worded to
      # stay true after a worker restart, when the offer itself is gone.
      OFFER_LINE = "Where it stands now: the last turn stopped at its step limit before the task was finished."
      OMITTED = "(earlier part omitted)"
      DEFAULT_SENTENCES = [2, 4].freeze
      MAX_SENTENCES = 10
      SENTENCES_RE = /\A(\d+)(?:\s*[-–]\s*(\d+))?\z/

      module_function

      # The recap.sentences setting as [min, max]: "2-3", "3" or 3 (an en
      # dash and spaces are fine). DEFAULT_SENTENCES when unset; nil when
      # invalid (outside 1..MAX_SENTENCES, min above max, not a number).
      def sentences_range(value)
        text = value.to_s.strip
        return DEFAULT_SENTENCES if text.empty?

        match = SENTENCES_RE.match(text)
        return nil unless match

        min = match[1].to_i
        max = (match[2] || match[1]).to_i
        return nil unless min.between?(1, MAX_SENTENCES) && max.between?(min, MAX_SENTENCES)

        [min, max]
      end

      # @return [Array<Hash>, nil] chat messages; nil when there is no
      #   transcript to summarize
      # @param sentences [Array(Integer, Integer)] the range, from #sentences_range
      # @param offer [Boolean] a continue offer is open: add OFFER_LINE
      def build(transcript, tool_count: nil, tool_names: [], previous: nil, sentences: DEFAULT_SENTENCES, offer: false)
        body = cap(transcript.to_s.strip)
        return nil if body.empty?

        tool_count ||= tool_names.size
        count_word = tool_count == 1 ? "1 tool call" : "#{tool_count} tool calls"
        tools = if tool_count > LARGE_TOOL_THRESHOLD
                  " #{count_word}#{tools_used(tool_names)} were made. Do not enumerate the tool calls."
                elsif tool_count.positive?
                  " About #{count_word}#{tools_used(tool_names)} were made; name them only if they " \
                    "matter to the result."
                else
                  ""
                end
        one = sentences.last == 1
        range = { plain: sentences_text(sentences, "plain "), sentences: sentences_text(sentences),
                  shape: one ? ONE_SHAPE : SHAPE, focus: one ? "it" : "the first sentence" }
        system = format(SYSTEM, range) + (previous ? UPDATE + format(UPDATE_LENGTH, range) : "") + tools
        user = +""
        user << "Earlier recap:\n#{previous}\n\n" if previous
        user << "Transcript#{previous ? ' since the earlier recap' : ''} (the system prompt and tool " \
                "internals were removed; only user turns and assistant prose remain):\n---\n#{body}\n---\n"
        user << "#{OFFER_LINE}\n" if offer
        user << "Write the recap now."
        [{ role: "system", content: system }, { role: "user", content: user }]
      end

      # "2-4 sentences", or "3 sentences" for [3, 3] ("1 sentence" for [1, 1])
      def sentences_text((min, max), adjective = "")
        count = min == max ? min.to_s : "#{min}-#{max}"
        "#{count} #{adjective}#{max == 1 ? 'sentence' : 'sentences'}"
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

    # @return [Array(Integer, Integer)] the recap length range, e.g. [2, 4]
    attr_reader :generation, :inactivity, :min_user_turns, :sentences

    # @param callable [#call] true while a continue offer waits for an
    #   answer (the Worker's or the REPL's TurnFlow); read at each attempt
    attr_writer :awaiting_continue

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

    # The recap asks either a fixed model (+model+, +base_url+,
    # +api_key_env+: an explicit recap: config) or +target+, called at each
    # attempt (the session's current model, so a /model switch counts).
    # @param base_url [String] the OpenAI API base the recap asks
    # @param api_key_env [String, nil] the variable holding its key
    # @param target [#call, nil] -> {base_url:, api_key_env:, model:, label:}
    def initialize(engine:, model: nil, base_url: nil, api_key_env: nil, target: nil,
                   inactivity: DEFAULT_INACTIVITY_SECONDS,
                   min_user_turns: DEFAULT_MIN_USER_TURNS,
                   timeout: DEFAULT_TIMEOUT_SECONDS,
                   sentences: RecapPrompt::DEFAULT_SENTENCES,
                   client: nil,
                   store: nil,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      raise ArgumentError, "IdleRecap requires an engine" unless engine

      @engine = engine
      @target = target || lambda {
        { base_url: base_url, api_key_env: api_key_env, model: model, label: model }
      }
      @inactivity = inactivity
      @min_user_turns = min_user_turns
      @timeout = timeout
      @sentences = sentences
      # Specs inject a client; otherwise one IdleClient per target, rebuilt
      # when the target changes.
      @client_override = client
      @client = nil
      @client_key = nil
      @clock = clock
      @store = store

      @mutex = Monitor.new
      # Serializes the attempt state machine (#tick on the scheduler thread,
      # #request_now on a Bridge or REPL thread, #write_now). Never held by
      # #state, so a snapshot reading it doesn't wait on an emit.
      @run_mutex = Monitor.new
      @generation = 0
      @last_fire_activity_seq = nil
      @awaiting_continue = -> { false }
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
      @run_mutex.synchronize do
        next collect if in_flight?
        next unless should_fire?

        start
      end
    end

    # Ask for a recap now (/recap): start an attempt at once, without the
    # inactivity window; the scheduler collects it as usual.
    # @return [Symbol] :started, :in_flight, :busy (a turn runs),
    #   :too_short, :nothing_new or :failed
    def request_now
      @run_mutex.synchronize do
        next :in_flight if in_flight?
        next :busy if @engine.turn_running?

        start
      end
    end

    # Write a recap now and wait for it, bounded by the timeout: the worker
    # (or the REPL) leaving. Skips the inactivity window and the once-per-
    # window latch, not the rules on what to recap (minimum user turns,
    # something new). Takes over an attempt already in flight. Call it with
    # the idle scheduler stopped.
    # @param on_start [#call, nil] called when a request goes out
    # @return [String, nil] the recap written, nil when none was
    def write_now(on_start: nil)
      @run_mutex.synchronize do
        unless in_flight?
          start
          on_start&.call if in_flight?
        end
        job = @in_flight
        next nil unless job

        job[:thread].join([job[:deadline] - @clock.call, 0].max)
        if job[:thread].alive?
          @in_flight = nil # overdue: left to its IdleClient timeout
          next nil
        end
        before = @state
        collect
        @state.equal?(before) ? nil : @state[:text]
      end
    end

    # @return [Hash] the model the next attempt asks: {base_url:,
    #   api_key_env:, model:, label:}
    def target
      @target.call
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

    # A failing check writes the recap without the offer line.
    def offer_open?
      @awaiting_continue.call ? true : false
    rescue StandardError
      false
    end

    def last_idle_seconds
      @clock.call - @engine.last_activity_at
    end

    # Start an attempt: snapshot, build the prompt, and spawn the summarize
    # thread. The result is picked up by #collect on a later tick.
    # @return [Symbol] :started, :too_short, :nothing_new or :failed
    def start
      gen = bump_generation
      # Latch the attempt, not the success: a short history, a failed or
      # empty summary, or an invalidated run must not re-fire on every
      # scheduler tick. The next recorded activity re-arms the window.
      @last_fire_activity_seq = @engine.activity_seq
      parsed = safe_parse(@engine.messages_json_for_recap)
      return :too_short if parsed.nil?

      user_turns = parsed.count { |message| message.is_a?(Hash) && message["role"] == "user" }
      if parsed.empty? || user_turns < @min_user_turns
        drop_stale(parsed)
        return :too_short
      end
      previous = continuable_state(parsed)
      fresh = parsed.drop(previous ? previous[:covered] : 0)
      transcript = TranscriptFilter.build(fresh)
      # Nothing new said (only notes, tool traffic, or no messages at all):
      # the recap still stands, so no request.
      return :nothing_new if transcript.strip.empty?
      prompt = RecapPrompt.build(transcript, tool_names: TranscriptFilter.tool_names(fresh), previous: previous&.dig(:text),
                                                     sentences: @sentences, offer: offer_open?)
      return :nothing_new if prompt.nil?
      asked = target
      @in_flight = { thread: spawn_summarize(client_for(asked), prompt), generation: gen, deadline: @clock.call + @timeout,
                     covered: parsed.size, covered_digest: self.class.digest(parsed.last), model: asked[:label] }
      :started
    rescue StandardError
      :failed
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
      # An IdleClient::Summary names the model that answered; a plain String
      # (a stubbed client) doesn't, and the asked label stands in.
      served = recap.model if recap.respond_to?(:model)
      text = recap.to_s
      saved = { text: text, covered: job[:covered], covered_digest: job[:covered_digest],
                model: served || job[:model], created_at: Time.now.utc.iso8601 }
      @mutex.synchronize { @state = saved }
      save(saved)
      @engine.emit_recap(recap: text, generation: job[:generation], covered: job[:covered])
    rescue StandardError
      @in_flight = nil
    end

    # A history too short for a recap that no longer holds what the saved one
    # covers (a "no" at a continue offer took the offered turn back): the
    # saved recap would keep describing that turn, so it goes.
    def drop_stale(messages)
      return unless state
      return if continuable_state(messages)

      @mutex.synchronize { @state = nil }
      @store&.delete
    rescue StandardError => e
      Log.warn(:recap, "delete_failed", echo: "[IdleRecap] dropping a stale recap failed: #{e.class}: #{e.message}", error: e.class.name)
    end

    def save(state)
      @store&.save(state)
    rescue StandardError => e
      Log.warn(:recap, "save_failed", echo: "[IdleRecap] saving the recap failed: #{e.class}: #{e.message}", error: e.class.name)
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

    def client_for(asked)
      return @client_override if @client_override

      key = asked.values_at(:base_url, :api_key_env, :model)
      unless @client && @client_key == key
        @client = IdleClient.new(model: asked[:model], base_url: asked[:base_url], api_key_env: asked[:api_key_env], timeout: @timeout)
        @client_key = key
      end
      @client
    end

    def spawn_summarize(client, prompt)
      Thread.new do
        client.summarize(prompt)
      rescue StandardError => e
        # No recap this time (the next idle window tries again); say why.
        Log.exception(:recap, "summarize_failed", e)
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
