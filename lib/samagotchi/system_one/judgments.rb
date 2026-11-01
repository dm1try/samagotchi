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
      Declaration = Data.define(:name, :questions, :positive, :negative, :shared_host) do
        # @raise [ArgumentError] anything the declaration can't be
        def self.build(bundle:, name:, questions:, positive: nil, negative: nil, shared_host: :skip)
          full = "#{bundle}.#{name}"
          unless Runs.declarable?(full)
            raise ArgumentError, "judgment #{full.inspect}: a full name is dot-separated words of a-z, 0-9, _ and -, " \
                                 "with no first word of #{Runs::RESERVED.join(", ")} and no #{Runs::RESERVED_SUFFIX} at its end"
          end
          unless SHARED_HOST.include?(shared_host)
            raise ArgumentError, "judgment #{full}: shared_host: is #{SHARED_HOST.map(&:inspect).join(" or ")}, not #{shared_host.inspect}"
          end

          new(name: full, questions: questions.respond_to?(:call) ? questions : checked(full, questions),
              positive: Array(positive).map(&:to_s).freeze, negative: Array(negative).map(&:to_s).freeze, shared_host: shared_host)
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

      SHARED_HOST = %i[ask skip].freeze

      # What an ask came to. +reason+ says why there's no answer: :off,
      # :no_host, :no_session, :failed, :cancelled, :shared_host or :busy; nil
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
      Ask = Data.define(:client, :questions, :state, :run_id, :mode, :shared_host)

      # The seams are what the Engine knows, read at each ask. They default to
      # nothing, for a chi with no Engine (a bundle's install check): nothing
      # is ever answered there.
      # @param settings [#call] (name) → JudgmentSettings
      # @param client_for [#call] (name, settings) → a Client, nil with no host
      # @param runs [#call] → the Runs to save in
      # @param where [#call] → Recording::Context, nil with no session
      # @param side [SideJudgments]
      # @param shared_host_busy [#call] (host) → whether a turn is running on it
      # @param participant [#call] → whether a participant's turn runs: its
      #   text is never saved
      def initialize(settings: JudgmentSettings.method(:of), client_for: ->(_name, _settings) {}, runs: -> { Runs.new }, where: -> {},
                     side: SideJudgments.new, shared_host_busy: ->(_host) { false }, participant: -> { false })
        @settings = settings
        @client_for = client_for
        @runs = runs
        @where = where
        @side = side
        @shared_host_busy = shared_host_busy
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

        shared_host?(ask) ? skipped(ask, :shared_host) : asked(ask, cancel_controller)
      end

      # Ask on +name+'s side thread, one at a time; the block gets the Result
      # on another thread, always once.
      # @return [String, nil] the run's id, nil when no run will be saved
      # @raise [ArgumentError] as #judge
      def later(name, state:, context: nil, &block)
        ask = prepare(name, state, context)
        return tell(name, block, ask).run_id if ask.is_a?(Result)
        return tell(name, block, skipped(ask, :shared_host)).run_id if shared_host?(ask)

        started = @side.start(name, warn: warner(name, "judge_later_failed"),
                                    finish: ->(result) { deliver(name, block, result || Result.none(:failed, mode: ask.mode, run_id: ask.run_id)) }) do
          asked(ask, nil)
        end
        tell(name, block, skipped(ask, :busy)) unless started
        ask.run_id
      end

      # A later line on a run (Runs#label, #acted); false when it isn't saved.
      def label(run_id, value, by:, strength: nil, question: nil)
        @runs.call.label(run_id, value, by: by, strength: strength, question: question)
      end

      def acted(run_id, what) = @runs.call.acted(run_id, what)

      # One warn per system_one.judgments name no plugin declared, once the
      # plugins have loaded: a typo there is a judgment that stays off.
      # Core's names have their own warning (Config.validate_yaml_sections).
      def warn_undeclared
        known = @mutex.synchronize { @declarations.keys }
        (JudgmentSettings.names - known).each do |name|
          next if Config::RESERVED_JUDGMENTS.include?(name.split(".").first)

          Samagotchi::Log.warn(:config, "judgment_undeclared", echo: "Warning: config: system_one.judgments.#{name}: no installed bundle declares it")
        end
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
                questions: declaration.questions_for(context), state: Runs.scrubbed(state),
                run_id: runs.on? ? Runs.new_id(declaration.name) : nil, mode: settings.mode, shared_host: declaration.shared_host)
      end

      def client_for(declaration, settings)
        @client_for.call(declaration.name, settings)
      rescue StandardError => e
        warner(declaration.name, "judgment_client_failed").call(e)
        nil
      end

      # Whether this ask would evict a running turn's cached prompt, and its
      # bundle said to skip then. A check that fails counts as yes: no ask.
      def shared_host?(ask)
        ask.shared_host == :skip && @shared_host_busy.call(ask.client.host)
      rescue StandardError => e
        Samagotchi::Log.warn(:plugins, "judgment_shared_host_check_failed", error: e.class.name)
        true
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
