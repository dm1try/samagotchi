# frozen_string_literal: true

require_relative "../llm/errors"
require_relative "../side_judgments"
require_relative "../system_one/answer"
require_relative "../system_one/client"
require_relative "../system_one/errors"
require_relative "../system_one/fake_backend"
require_relative "../system_one/judgments"

module Samagotchi
  module Testing
    # A ctx.judge or ctx.judge_later that reached System 1. +cancel+ is the
    # controller it would stop with (nil for a judge_later's).
    JudgmentAsk = Data.define(:name, :state, :questions, :cancel)

    # What bundle.judgments is: chi's real SystemOne::Judgments, Client,
    # Recording and Runs, with a FakeBackend per judgment and the runs in
    # memory. So a judgment's off, skip, busy and failure paths are chi's own.
    # Each judgment is on until the test says otherwise (chi's are off until
    # the user sets a mode, which isn't the bundle's to test).
    #
    #   bundle.judgments.answer("progress", noul: 0.9)
    #   bundle.fire(:after_turn)
    #   bundle.judgments.wait                     # judge_later's thread, and its block
    #   bundle.judgments.asks.last.state
    #   bundle.judgments.runs("progress").last["answers"]
    #   bundle.judgments.labels("progress").map { _1["value"] }
    class Judgments
      # The backend behind one judgment: records the ask, stops if it's cancelled.
      class Backend < SystemOne::FakeBackend
        def initialize(owner, name)
          @owner = owner
          @name = name
          super() { |state, questions| owner.answers_for(name, state, questions) }
        end

        def ask(state:, questions:, cancel_controller: nil, observer: nil)
          @owner.asked(JudgmentAsk.new(name: @name, state: state, questions: questions, cancel: cancel_controller))
          raise LLM::RequestCancelled, :manual if cancel_controller&.cancelled?

          super
        end
      end

      # @return [SystemOne::Judgments] what the Host and registries hold
      attr_reader :layer

      # @param recorder [Recorder] the session's values: session_id, scratch,
      #   model_name and turn_author are read at each ask
      def initialize(recorder)
        @recorder = recorder
        @scope = nil
        @mutex = Mutex.new
        @answers = Hash.new { |hash, name| hash[name] = {} }
        @failing = {}
        @modes = {}
        @no_host = {}
        @asks = []
        @store = SystemOne::Runs::MemoryStore.new
        @side = SideJudgments.new
        @layer = build_layer
      end

      # Which bundle's short names these are (Bundle#judgments).
      # @return [Judgments] self
      def scoped(bundle)
        @scope = bundle
        self
      end

      # What the judgment answers from now on, until the next #answer: the
      # Answer's fields (noul:, choice:, score:, confidence:), or a block given
      # the state and returning them, which may also block, to hold a
      # judge_later in flight. A question with no answer set is no judgment.
      # @param question [String, nil] nil: every question that has none of its own
      # @return [Judgments] self
      def answer(name, question: nil, **fields, &block)
        @mutex.synchronize do
          @answers[full(name)][question&.to_s || :any] = block || fields
          @failing.delete(full(name))
        end
        self
      end

      # The backend fails from now on, until the next #answer: a failed run.
      # @return [Judgments] self
      def fail(name, error: "fake System 1 is unavailable")
        @mutex.synchronize { @failing[full(name)] = error }
        self
      end

      # The judgment's mode: "off", "audit" or "on" (the default here).
      # @return [Judgments] self
      def mode(name, word)
        @mutex.synchronize { @modes[full(name)] = word.to_s }
        self
      end

      # No System 1 host is configured for the judgment.
      # @return [Judgments] self
      def no_host(name)
        @mutex.synchronize { @no_host[full(name)] = true }
        self
      end

      # Wait for judge_later's asks and blocks, and for the blocks of those
      # that asked nothing.
      # @return [Judgments] self
      def wait(seconds = 5)
        @side.join(seconds)
        self
      end

      # Every ask that reached System 1, in order.
      # @return [Array<JudgmentAsk>]
      def asks = @mutex.synchronize { @asks.dup }

      # The runs saved, as chi saves them (docs/system-one.md).
      # @return [Array<Hash>]
      def runs(name) = lines(name, "run")

      # The label lines saved.
      # @return [Array<Hash>]
      def labels(name) = lines(name, "label")

      # The acted lines saved.
      # @return [Array<Hash>]
      def acted_lines(name) = lines(name, "acted")

      # @api private
      def asked(ask)
        @mutex.synchronize { @asks << ask }
      end

      # @api private: Backend's answers, one per question that has one.
      def answers_for(name, state, questions)
        answers, error = @mutex.synchronize { [@answers[name].dup, @failing[name]] }
        raise SystemOne::BackendError, error if error

        questions.to_h do |question|
          entry = answers.fetch(question.id) { answers[:any] }
          entry = entry.call(state) if entry.respond_to?(:call)
          [question.id, entry && SystemOne::Answer.new(id: question.id, type: question.type, **entry)]
        end.compact
      end

      private

      def lines(name, kind) = @store.lines[full(name)].select { |line| line["kind"] == kind }

      def full(name)
        name = name.to_s
        @scope && !@layer.declared?(name) ? "#{@scope}.#{name}" : name
      end

      def build_layer
        SystemOne::Judgments.new(
          settings: ->(name) { @mutex.synchronize { SystemOne::JudgmentSettings.new(mode: @modes.fetch(name, "on")) } },
          client_for: lambda { |name, settings|
            next nil if @mutex.synchronize { @no_host[name] }

            SystemOne::Client.new(backend: Backend.new(self, name), mode: settings.mode, host: "fake", model: "fake", tag: :plugins)
          },
          runs: -> { SystemOne::Runs.new(store: @recorder[:scratch] ? nil : @store) },
          where: lambda {
            id = @recorder[:session_id]
            id && SystemOne::Recording::Context.new(session_id: id, session_model: @recorder[:model_name])
          },
          side: @side,
          participant: -> { !@recorder[:turn_author].nil? }
        )
      end
    end
  end
end
