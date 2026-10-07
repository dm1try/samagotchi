# frozen_string_literal: true

require_relative "../idle_client"
require_relative "../idle_target"
require_relative "../cancellation_controller"
require_relative "../log"
require_relative "tags"

module Samagotchi
  module Broadcast
    # Whether a broadcast concerns a recipient its tags didn't match: a
    # small model reads the note and the session's ScopeCard and answers
    # yes or no (Triage::LLM). Many recipients are judged in parallel under
    # one deadline (Triage.judge_all); whatever isn't judged by then, or
    # fails, is delivered unchecked (fail open: a missed recipient is worse
    # than an extra note).
    module Triage
      # One recipient's verdict.
      # @!attribute relevant [Boolean] it gets the note
      # @!attribute p [Float, nil] the model's P(yes) from its logprobs,
      #   1.0 or 0.0 from a plain answer, nil when no model judged it
      # @!attribute reason [String] why, for the output and the log
      # @!attribute by [String] who decided: "tags" (a shared tag),
      #   "model", "fallback" (delivered unchecked: deadline, error, an
      #   answer that is no yes or no), "scope" (the note's first line
      #   names another project), "all" (--all) or "repl" (a chi REPL owns
      #   it: no notes)
      # @!attribute match [Match, nil] the shared tag (by "tags")
      Verdict = Data.define(:relevant, :p, :reason, :by, :match) do
        def initialize(match: nil, **) = super

        def unchecked? = by == "fallback"
      end

      # The spike's prompt (plain yes/no beat JSON with a p and a reason
      # for every model tried: writing a reason pushes towards "relevant").
      SYSTEM = <<~TEXT
        You route short notes that a developer broadcasts to their running coding-agent sessions.
        You get one note and one session's card (project, branch, title, what the session was started for, its latest recap, the last request).
        Decide whether the note may affect THIS session's current work: would the agent working on it want to know?
        A note can start with an informal scope line (a project, a component, a team); use it as a hint.
        Notes about things unrelated to the session's work (social, other projects, other components) are not relevant.
        Answer with exactly one word: yes or no.
      TEXT

      DEFAULT_PARALLEL = 4
      DEFAULT_DEADLINE = 20.0
      DEFAULT_THRESHOLD = 0.5
      # How long the threads still asking get to stop once the deadline
      # passed, all of them together (then they are killed).
      JOIN_GRACE = 1.0

      module_function

      # @return [Verdict] delivered unchecked, +why+ in the reason
      def unchecked(why) = Verdict.new(relevant: true, p: nil, reason: "unchecked: #{why}", by: "fallback")

      # The messages a model judges +note+ for +card+ by.
      def messages(note, card)
        [{ role: "system", content: SYSTEM }, { role: "user", content: "NOTE:\n#{note}\n\nSESSION CARD:\n#{card}" }]
      end

      # The one project the note's first line names, as a whole word (any
      # case), among +projects+ (the recipients' project names); nil when it
      # names none or several. A scope line ("shopfront/checkout", "agentd
      # web") then keeps the note to that project's sessions; anything
      # fuzzier is the model's job.
      # @param projects [Array<String>]
      # @return [String, nil]
      def scope_project(note, projects)
        line = note.to_s.lines.first.to_s.downcase
        named = projects.compact.uniq.select do |project|
          line.match?(/(?<![[:alnum:]_-])#{Regexp.escape(project.downcase)}(?![[:alnum:]_-])/)
        end
        named.one? ? named.first : nil
      end

      # Every card's verdict: a shared tag delivers (Tags.match); a note
      # whose first line names one of the projects (scope_project) skips
      # the other projects' sessions; the model judges the rest
      # (judge_all, +judge+ its keywords).
      # @param cards [Array<ScopeCard>]
      # @param note_tags [Array<Tag>]
      # @return [Hash{String => Verdict}] by card id, in +cards+' order
      def verdicts(note, cards, note_tags:, new_backend:, **judge)
        scope = scope_project(note, cards.map(&:project))
        decided = cards.to_h do |card|
          match = Tags.match(note_tags, card.tags)
          verdict = if match
                      Verdict.new(relevant: true, p: nil, reason: match.reason, by: "tags", match: match)
                    elsif scope && card.project != scope
                      Verdict.new(relevant: false, p: nil, reason: "scope line names #{scope}", by: "scope")
                    end
          [card.id, verdict]
        end
        judged = judge_all(note, cards.reject { |card| decided[card.id] }, new_backend: new_backend, **judge)
        cards.to_h { |card| [card.id, decided[card.id] || judged.fetch(card.id)] }
      end

      # Judges +cards+ with at most +parallel+ backends at a time, one per
      # thread (a backend keeps per-host state), all under +deadline+
      # seconds. A card not judged by then is delivered unchecked; the
      # requests still running are cancelled.
      # @param new_backend [#call] (CancellationController) → a backend:
      #   #judge(note, card) → Verdict
      # @param cards [Array<ScopeCard>]
      # @return [Hash{String => Verdict}] by card id
      def judge_all(note, cards, new_backend:, parallel: DEFAULT_PARALLEL, deadline: DEFAULT_DEADLINE,
                    clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        return {} if cards.empty?

        queue = Queue.new
        cards.each { |card| queue << card }
        queue.close
        results = {}
        lock = Mutex.new
        changed = ConditionVariable.new
        cancel = CancellationController.new
        ends = clock.call + deadline.to_f
        finished = 0
        threads = Array.new(parallel.to_i.clamp(1, cards.size)) do
          Thread.new do
            card = nil
            backend = new_backend.call(cancel)
            while (card = queue.pop)
              verdict = judge_one(backend, note, card)
              lock.synchronize do
                results[card.id] = verdict unless cancel.cancelled?
                changed.broadcast
              end
              card = nil
            end
          rescue StandardError => e
            # No backend (or a bug around it): this thread's card and the
            # ones it takes from here on are delivered unchecked at once,
            # so nobody waits for the deadline.
            Log.exception(:broadcast, "triage_thread_failed", e)
            failed = unchecked("triage failed (#{e.class})")
            lock.synchronize { results[card.id] ||= failed if card }
            while (card = queue.pop)
              lock.synchronize { results[card.id] ||= failed }
            end
          ensure
            lock.synchronize do
              finished += 1
              changed.broadcast
            end
          end
        end
        lock.synchronize do
          loop do
            break if results.size == cards.size || finished == threads.size

            left = ends - clock.call
            break if left <= 0

            changed.wait(lock, left)
          end
          cancel.cancel!(:deadline)
          queue.clear
        end
        grace_ends = clock.call + JOIN_GRACE
        threads.each { |thread| thread.join([grace_ends - clock.call, 0].max) || thread.kill }
        cards.to_h { |card| [card.id, results[card.id] || unchecked("triage deadline")] }
      end

      def judge_one(backend, note, card)
        backend.judge(note, card)
      rescue Samagotchi::LLM::RequestCancelled
        unchecked("triage deadline")
      rescue StandardError => e
        Log.exception(:broadcast, "triage_failed", e)
        unchecked("triage failed (#{e.class})")
      end
      private_class_method :judge_one

      # A triage model on an OpenAI-compatible host (an IdleTarget), asked
      # through its own IdleClient: thinking off, a few tokens, the first
      # token's logprobs when the host gives them. P(yes) / (P(yes) +
      # P(no)) from those is graded against +threshold+; a plain yes or no
      # is 1.0 or 0.0.
      class LLM
        MAX_TOKENS = 16
        TOP_LOGPROBS = 5
        LOGPROB_OPTIONS = { logprobs: true, top_logprobs: TOP_LOGPROBS }.freeze
        # Hosts (base urls) that refused logprobs with a 400: asked without
        # them from then on, in this process.
        @no_logprobs = Set.new
        @no_logprobs_lock = Mutex.new

        class << self
          def logprobs?(base_url) = @no_logprobs_lock.synchronize { !@no_logprobs.include?(base_url) }

          def no_logprobs!(base_url) = @no_logprobs_lock.synchronize { @no_logprobs << base_url }

          # Specs: forget the hosts that refused.
          def reset_logprobs! = @no_logprobs_lock.synchronize { @no_logprobs.clear }
        end

        # @param target [IdleTarget]
        # @param timeout [Numeric] each request's
        # @param client [IdleClient, nil] specs inject one
        def initialize(target:, timeout:, threshold: DEFAULT_THRESHOLD, cancel_controller: nil, client: nil)
          @target = target
          @threshold = threshold.to_f
          @cancel = cancel_controller
          @client = client || IdleClient.for(target, timeout: timeout, purpose: "broadcast")
        end

        # @return [Verdict]
        # @raise [Samagotchi::LLM::RequestCancelled] the deadline passed
        def judge(note, card)
          answer = ask(Triage.messages(note, card))
          word = self.class.word(answer.text)
          return Triage.unchecked("the model answered #{answer.text.to_s.strip[0, 40].inspect}") unless word

          p = self.class.logprob_p(answer.top_logprobs, word: word)
          relevant = p ? p >= @threshold : word == "yes"
          reason = "model: #{relevant ? "yes" : "no"}#{format(" (p %.2f)", p) if p}"
          Verdict.new(relevant: relevant, p: p || (word == "yes" ? 1.0 : 0.0), reason: reason, by: "model")
        rescue IdleClient::SummarizeError => e
          Triage.unchecked("the model failed (#{e.message[0, 120]})")
        end

        # "yes" or "no": the answer's first such word (thinking left out),
        # nil when it has neither.
        def self.word(text)
          text.to_s.gsub(%r{<think>.*?</think>}m, "").strip.downcase[/\A\W*(yes|no)\b/, 1]
        end

        # P(yes) / (P(yes) + P(no)) over the first token's alternatives
        # ("Yes", " yes" count as yes), when that token is the answer +word+
        # itself: its likeliest alternative is yes or no and agrees with
        # +word+. nil otherwise (an answer starting "**", "<think>" or a
        # quote: those alternatives say nothing about yes or no).
        # @param top [Array<Samagotchi::LLM::TokenLogprob>]
        # @return [Float, nil]
        def self.logprob_p(top, word:)
          first = top.max_by(&:logprob)
          return nil unless first && first.token.strip.downcase == word

          sum = ->(want) { top.select { |t| t.token.strip.downcase == want }.sum { |t| Math.exp(t.logprob) } }
          yes = sum.call("yes")
          no = sum.call("no")
          (yes / (yes + no)).round(4)
        end

        private

        def ask(messages)
          base_url = @target.base_url
          options = self.class.logprobs?(base_url) ? LOGPROB_OPTIONS : {}
          begin
            @client.ask(messages, max_tokens: MAX_TOKENS, cancel_controller: @cancel, kind: "broadcast", options: options)
          rescue IdleClient::SummarizeError => e
            raise unless !options.empty? && e.cause.is_a?(Samagotchi::LLM::BadRequest)

            # The host won't give logprobs (a server that refuses "n and
            # logprobs"): ask again without, and leave them out from now on.
            self.class.no_logprobs!(base_url)
            Log.info(:broadcast, "logprobs_refused", model: @target.label, detail: e.cause.message.to_s[0, 200])
            options = {}
            retry
          end
        end
      end
    end
  end
end
