# frozen_string_literal: true

require_relative "../config"
require_relative "../log"
require_relative "../llm/errors"
require_relative "../side_judgments"
require_relative "judgment_settings"
require_relative "question"
require_relative "recording"
require_relative "runs"

module Samagotchi
  module SystemOne
    # Bundles' judgments (chi.judgment, ctx.judge, ctx.judge_later): what the
    # user set for each, then the same Client and Recording core's uses ask
    # through. It adds no power: a bundle's run is scoped to its name, and off
    # until the user sets a mode. Core's uses stay outside (their threads,
    # gates and contention are their own) and can't be set here (D2,
    # JudgmentSettings).
    class Judgments
      # What chi.judgment declared. +questions+ is an Array of Question, or a
      # callable given the ctx, returning what normalize_questions takes.
      Declaration = Data.define(:name, :questions, :positive, :negative) do
        # @raise [ArgumentError] anything the declaration can't be
        def self.build(bundle:, name:, questions:, positive: nil, negative: nil)
          full = "#{bundle}.#{name}"
          # The first word is the bundle: "a.b" + "x" and "a" + "b.x" must not meet.
          raise ArgumentError, "judgment #{full.inspect}: a bundle with a dot in its name can't declare one" if bundle.to_s.include?(".")

          unless Runs.declarable?(full)
            raise ArgumentError, "judgment #{full.inspect}: a full name is dot-separated words of a-z, 0-9, _ and -, " \
                                 "with no first word of #{Runs::RESERVED.join(", ")} and no #{Runs::RESERVED_SUFFIX} at its end"
          end

          new(name: full, questions: questions.respond_to?(:call) ? questions : checked(full, questions),
              positive: Array(positive).map(&:to_s).freeze, negative: Array(negative).map(&:to_s).freeze)
        end

        # The questions of an ask now.
        # @return [Array<Question>]
        def questions_for(context)
          questions.respond_to?(:call) ? self.class.checked(name, questions.call(context)) : questions
        end

        def self.checked(full, questions)
          list = SystemOne.normalize_questions(questions)
          raise ArgumentError, "judgment #{full} has no questions" if list.empty?

          list.freeze
        end

        # What each of its runs says of the label values, if anything.
        def run_fields = { positive: positive, negative: negative }.reject { |_key, values| values.empty? }
      end

      # What an ask came to. +reason+ says why there's no answer: :off,
      # :no_host, :no_session, :failed, :cancelled or :busy; nil
      # with answers. +mode+ is the judgment's ("off", "audit", "on"): in audit
      # the bundle looks and doesn't act. +run_id+ is nil when no run is saved.
      Result = Data.define(:answers, :run_id, :mode, :reason) do
        def self.none(reason, mode: "off", run_id: nil) = new(answers: {}.freeze, run_id: run_id, mode: mode, reason: reason)

        def no_judgment? = answers.empty?
        def audit? = mode == "audit"

        # An :noul question's probability of yes; nil with no answer, or for
        # another type (its answer is #answers[id]).
        # @param id [String, Symbol, nil] nil: the only question's
        # @return [Float, nil]
        def p(id = nil)
          answer = id.nil? ? (answers.values.first if answers.size == 1) : answers[id.to_s]
          answer&.noul
        end
      end

      # One ask, made ready on the caller's thread.
      Ask = Data.define(:client, :questions, :state, :run_id, :mode)

      # The seams are what the Engine knows, read at each ask. They default to
      # nothing, for a chi with no Engine (a bundle's install check): nothing
      # is ever answered there.
      # @param settings [#call] (name) → JudgmentSettings
      # @param client_for [#call] (name, settings) → a Client, nil with no host
      # @param runs [#call] → the Runs to save in
      # @param where [#call] → Recording::Context, nil with no session
      # @param side [SideJudgments]
      # @param participant [#call] → whether a participant's turn runs: its
      #   text is never saved
      def initialize(settings: JudgmentSettings.method(:of), client_for: ->(_name, _settings) {}, runs: -> { Runs.new }, where: -> {},
                     side: SideJudgments.new, participant: -> { false })
        @settings = settings
        @client_for = client_for
        @runs = runs
        @where = where
        @side = side
        @participant = participant
        @declarations = {}
        @mutex = Mutex.new
      end

      # @param declaration [Declaration]
      def declare(declaration)
        @mutex.synchronize { @declarations[declaration.name] = declaration }
      end

      def declared?(name) = @mutex.synchronize { @declarations.key?(name.to_s) }

      # Ask now, on this thread.
      # @param context [Object] what a questions builder gets (the ctx)
      # @return [Result]
      # @raise [ArgumentError] +name+ isn't declared, or +state+ can't be one
      def judge(name, state:, context: nil, cancel_controller: nil)
        ask = prepare(name, state, context)
        return ask if ask.is_a?(Result)

        asked(ask, cancel_controller)
      end

      # Ask on +name+'s side thread, one at a time; the block gets the Result
      # on another thread, always once.
      # @return [String, nil] the run's id, nil when no run will be saved
      # @raise [ArgumentError] as #judge
      def later(name, state:, context: nil, &block)
        ask = prepare(name, state, context)
        return tell(name, block, ask).run_id if ask.is_a?(Result)

        started = @side.start(name, warn: warner(name, "judge_later_failed"),
                                    finish: ->(result) { deliver(name, block, result || Result.none(:failed, mode: ask.mode, run_id: ask.run_id)) }) do
          asked(ask, nil)
        end
        tell(name, block, skipped(ask, :busy)) unless started
        ask.run_id
      end

      # A later line on a run (Runs#label, #acted); false when it isn't saved.
      # Nothing is saved in a participant's turn, as an ask there saves no run.
      def label(run_id, value, by:, strength: nil, question: nil)
        return false if @participant.call

        @runs.call.label(run_id, value, by: by, strength: strength, question: question)
      end

      def acted(run_id, what)
        return false if @participant.call

        @runs.call.acted(run_id, what)
      end

      # The system_one.judgments names no plugin declared, once the plugins
      # have loaded: a typo there is a judgment that stays off. Core's names
      # have their own warning (Config.validate_yaml_sections).
      # @return [Array<String>]
      def undeclared
        known = @mutex.synchronize { @declarations.keys }
        (JudgmentSettings.names - known).reject { |name| Config::RESERVED_JUDGMENTS.include?(name.split(".").first) }
      end

      private

      # The Ask, or the Result that says why there is none.
      def prepare(name, state, context)
        declaration = @mutex.synchronize { @declarations[name.to_s] }
        raise ArgumentError, "no judgment #{name} declared (chi.judgment)" unless declaration
        unless state.is_a?(String) || state.is_a?(Hash) || state.is_a?(Array)
          raise ArgumentError, "judgment #{name}: state: is a String, a Hash or an Array, not #{state.class}"
        end

        settings = @settings.call(declaration.name)
        return Result.none(:off) if settings.off?

        client = client_for(declaration, settings)
        return Result.none(:no_host, mode: settings.mode) if client.nil?

        where = where_now(declaration)
        return Result.none(:no_session, mode: settings.mode) if where.nil?

        ready(declaration, settings, client, where, state, context)
      end

      def where_now(declaration)
        @where.call
      rescue StandardError => e
        warner(declaration.name, "judgment_session_unread").call(e)
        nil
      end

      def ready(declaration, settings, client, where, state, context)
        runs = @participant.call ? Runs.new : @runs.call
        Ask.new(client: Recording.new(client, judgment: declaration.name, runs: runs, context: where, fields: declaration.run_fields),
                questions: declaration.questions_for(context), state: copy_of(declaration, state),
                run_id: runs.on? ? Runs.new_id(declaration.name) : nil, mode: settings.mode)
      end

      # A state nested too deep to copy (a cycle) is a bad state: a
      # SystemStackError would go past a hook's rescue and end the turn.
      def copy_of(declaration, state)
        Runs.scrubbed(state)
      rescue SystemStackError
        raise ArgumentError, "judgment #{declaration.name}: state: is nested too deep"
      end

      def client_for(declaration, settings)
        @client_for.call(declaration.name, settings)
      rescue StandardError => e
        warner(declaration.name, "judgment_client_failed").call(e)
        nil
      end

      def skipped(ask, reason)
        ask.client.skip(state: ask.state, questions: ask.questions, reason: reason.to_s, run_id: ask.run_id)
        Result.none(reason, mode: ask.mode, run_id: ask.run_id)
      end

      def asked(ask, cancel_controller)
        answers = ask.client.ask(state: ask.state, questions: ask.questions, cancel_controller: cancel_controller, run_id: ask.run_id)
        return Result.none(:failed, mode: ask.mode, run_id: ask.run_id) if answers.nil?

        Result.new(answers: answers.freeze, run_id: ask.run_id, mode: ask.mode, reason: nil)
      rescue LLM::RequestCancelled
        Result.none(:cancelled, mode: ask.mode, run_id: ask.run_id)
      end

      # The block gets +result+ on another thread, as an asked one does.
      # @return [Result] +result+
      def tell(name, block, result)
        @side.aside(warn: warner(name, "judge_later_failed")) { deliver(name, block, result) } if block
        result
      end

      def deliver(name, block, result)
        block&.call(result)
      rescue StandardError => e
        warner(name, "judge_later_block_failed").call(e)
      end

      def warner(name, event)
        lambda { |error|
          Samagotchi::Log.warn(:plugins, event, judgment: name, error: "#{error.class}: #{error.message}"[0, 300])
        }
      end
    end
  end
end
