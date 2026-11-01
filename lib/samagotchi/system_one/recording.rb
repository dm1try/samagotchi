# frozen_string_literal: true

require_relative "../llm/errors"
require_relative "../log"
require_relative "question"
require_relative "runs"

module Samagotchi
  module SystemOne
    # A Client that saves each ask as a run (Runs): the same duck type, the
    # same answers and the same raises. It sits where a use builds its
    # client, so gates, threads and domain logs stay the use's own. A run
    # that can't be saved is one warn and never changes the answer.
    #
    #   client = Recording.wrap(Client.from_config(...), judgment: "approvals.allow", runs: runs, context: context)
    #   client&.ask(state:, questions:, cancel_controller:)
    class Recording
      # What a run says about its session, taken on the caller's thread:
      # the ask itself may run on its own. +chain_link+ is the parent or the
      # session this one continues (a chain is derived, SessionChain, and
      # following it costs a listing), +session_model+ the session's model.
      Context = Data.define(:session_id, :chain_link, :session_model, :test_run) do
        def initialize(session_id: nil, chain_link: nil, session_model: nil, test_run: nil) = super

        def to_h = super.transform_keys(&:to_s)

        def self.of(session, session_model: nil)
          new(session_id: session&.id, chain_link: session&.parent_id || session&.continues,
              session_model: session_model, test_run: session&.test_run ? true : nil)
        end
      end

      # The wrapped client, or nil for none: the caller's nil check stays.
      # @param recorded_mode [String, nil] the use's mode as a run says it,
      #   where the client's isn't it (toolkit and context build theirs "on"
      #   in audit too); nil: the client's
      def self.wrap(client, judgment:, runs:, context: Context.new, recorded_mode: nil)
        client && new(client, judgment: judgment, runs: runs, context: context, recorded_mode: recorded_mode)
      end

      # @param fields [Hash] more for each of its runs (a bundle's judgment's
      #   positive: and negative: label values)
      def initialize(client, judgment:, runs:, context: Context.new, recorded_mode: nil, fields: {})
        @client = client
        @judgment = judgment
        @runs = runs
        @context = context
        @recorded_mode = recorded_mode
        @fields = fields
      end

      def host = @client.host
      def model = @client.model
      def mode = @client.mode
      def backend = @client.backend

      # Client#ask, recorded. A cancelled ask or one that raises records its
      # run, then raises as before.
      # @param run_id [String, nil] the run's id when the caller needs it at
      #   once (it is passed in, not read back: one client serves several
      #   threads); nil: a new one
      def ask(state:, questions:, cancel_controller: nil, run_id: nil)
        facts = {}
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        answers = @client.ask(state: state, questions: questions, cancel_controller: cancel_controller,
                              observer: ->(**told) { facts.merge!(told) })
        record(run_id, state, questions, answers, facts, started)
        answers
      rescue LLM::RequestCancelled
        record(run_id, state, questions, nil, facts.merge(failure: "cancelled"), started)
        raise
      rescue StandardError => e
        record(run_id, state, questions, nil, facts.merge(failure: e.class.name, failure_text: e.message), started)
        raise
      end

      # An ask that wasn't made: its run, at once, asked: false, so a later
      # replay can answer the state with no eviction today (docs/system-one.md).
      # @param reason [String] why: the run's +skipped+
      def skip(state:, questions:, reason:, run_id: nil)
        save(questions) do
          { id: run_id || Runs.new_id(@judgment), state: state, asked: false, skipped: reason, model: said(:model) }
        end
      end

      private

      def record(run_id, state, questions, answers, facts, started)
        save(questions) do
          { id: run_id || Runs.new_id(@judgment), state: state, asked: true, model: facts[:model] || said(:model),
            served_model: facts[:served_model], answers: facts[:raw] || answers&.transform_values(&:to_h), usage: facts[:usage],
            failure: facts[:failure], failure_text: facts[:failure_text]&.to_s&.slice(0, 500),
            latency_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round }
        end
      end

      # One run: the block's fields, and what every run says.
      def save(questions)
        return unless @runs.on?

        questions = SystemOne.normalize_questions(questions)
        return if questions.empty? # Client#ask asked nothing.

        @runs.record(judgment: @judgment, questions: questions, **@context.to_h.transform_keys(&:to_sym), **@fields,
                     origin: "live", mode: @recorded_mode || said(:mode), host: said(:host), **yield)
      rescue StandardError, SystemStackError => e # a state nested too deep to copy
        # Qualified: inside SystemOne, the bare Log is SystemOne::Log.
        Samagotchi::Log.warn(:system_one, "system_one_run_failed",
                             echo: "[samagotchi:system_one] a run wasn't saved: #{e.class}: #{e.message}",
                             judgment: @judgment, error: e.class.name)
      end

      # What the client says about itself; a stand-in may say nothing.
      def said(name) = @client.respond_to?(name) ? @client.public_send(name) : nil
    end
  end
end
