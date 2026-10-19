# frozen_string_literal: true

require "json"
require_relative "../../analytics_file"
require_relative "../../bridge/card_store"
require_relative "../../session"
require_relative "../../session_metrics"
require_relative "../../tool_response"

module Samagotchi
  class BundleCommand
    module Try
      Trace = Data.define(
        :session_id, :exit_code, :answer, :tools, :notices, :cards, :questions, :denied,
        :interactive_blocked, :used_memories, :tokens, :cost, :cost_is_estimate, :model, :sandbox, :stderr_tail,
        :timed_out
      )

      class TraceReader
        DENIAL_TEXT = "No one to approve it (non-interactive run)."
        STDERR_LIMIT = 4000

        def initialize(state_home:, session_id:)
          @state_home = state_home
          @session_id = session_id if Session.valid_id?(session_id)
        end

        def read(exit_code:, answer:, stderr:, sandbox:, timed_out: false)
          return empty_trace(exit_code, answer, stderr, sandbox, timed_out) unless @session_id

          sessions_dir = File.join(@state_home, Session::STATE_SUBDIR)
          session_dir = Session.session_dir(@session_id, state_dir: sessions_dir)
          session = json_file(Session.session_file(@session_id, state_dir: sessions_dir)) || {}
          messages = Array(session["messages"]).select { |message| message.is_a?(Hash) }
          analytics = AnalyticsFile.read(session_dir) || {}
          entries = card_entries(session_dir)
          tool_rows, denied = tools(messages, analytics)
          summary = SessionMetrics.saved_summary(session_dir)
          cost, estimate = cost_summary(summary)
          questions = entries.select { |entry| entry["type"] == "question" }
          notices = entries.select { |entry| entry["type"] == "hook_notice" }
          cards = entries.select { |entry| entry["type"] == "card" }
          blocked_count = questions.count { |question| unanswerable?(question) } + denied.size

          Trace.new(
            session_id: @session_id, exit_code: exit_code, answer: answer.to_s, tools: tool_rows, notices: notices,
            cards: cards, questions: questions, denied: denied, interactive_blocked: blocked_count.positive?,
            used_memories: Array(session["used_memory_names"]), tokens: {
                                                                  prompt: summary&.prompt_sum, completion: summary&.completion_sum
                                                                },
            cost: cost, cost_is_estimate: estimate, model: session["model_name"], sandbox: sandbox,
            stderr_tail: tail(stderr), timed_out: timed_out
          )
        end

        private

        def empty_trace(exit_code, answer, stderr, sandbox, timed_out)
          Trace.new(session_id: nil, exit_code: exit_code, answer: answer.to_s, tools: [], notices: [], cards: [],
                    questions: [], denied: [], interactive_blocked: false, used_memories: [], tokens: {
                      prompt: nil, completion: nil
                    }, cost: nil, cost_is_estimate: false, model: nil, sandbox: sandbox, stderr_tail: tail(stderr),
                    timed_out: timed_out)
        end

        # One row per saved call. A turn a --timeout interrupt cut (a
        # Ctrl-C) saves its calls too, the one it cut short answered as
        # interrupted (ToolResponse.interrupted): a record has no row of its
        # own, so no call shows twice.
        def tools(messages, analytics)
          records = Array(analytics["tool_records"]).select { |record| record.is_a?(Hash) }
                                                    .to_h do |record|
            [[record["iteration"].to_i, record["call_index"].to_i], record]
          end
          tool_responses = messages.select { |message| %w[tool_response tool].include?(message["role"]) }
          denied = []
          index = 0
          iteration = 0
          rows = messages.flat_map do |message|
            next [] unless %w[model assistant].include?(message["role"])

            iteration += 1
            Array(message["tool_calls"]).each_with_index.filter_map do |call, call_index|
              next unless call.is_a?(Hash)

              index += 1
              record = records[[iteration, call_index + 1]]
              id = call["id"]
              response = tool_responses.find { |entry| entry["tool_call_id"] == id } if id
              response ||= tool_responses[index - 1] unless id
              is_denied = response && response["content"].to_s.include?(DENIAL_TEXT)
              denied << index if is_denied
              status = is_denied ? "denied" : record&.dig("status").to_s
              status = "interrupted" if status.empty? && response && ToolResponse.interrupted_text?(response["content"])
              status = "unknown" if status.empty?
              {
                index: index,
                name: record&.[]("called_as") || record&.[]("tool") || call_name(call),
                args: argument_text(call),
                status: status,
                duration_ms: record&.[]("duration_ms").to_i
              }
            end
          end
          [rows, denied]
        end

        def call_name(call)
          function = call["function"].is_a?(Hash) ? call["function"] : {}
          call["name"] || function["name"] || "tool"
        end

        def argument_text(call)
          function = call["function"].is_a?(Hash) ? call["function"] : {}
          args = call["arguments"] || function["arguments"] || {}
          args = JSON.parse(args) if args.is_a?(String)
          if args.is_a?(Hash)
            preferred = %w[command content path url query].filter_map { |key| args[key] }.first
            args = preferred || JSON.generate(args)
          end
          args.to_s.gsub(/\s+/, " ").strip[0, 200]
        rescue JSON::ParserError
          args.to_s.gsub(/\s+/, " ").strip[0, 200]
        end

        # The listing's placement fields: nothing to place in a one-turn run.
        LISTING_FIELDS = %w[turns_since current earlier].freeze

        # The saved cards as the web reads them (CardStore.saved), with
        # string keys and values, as the JSON trace prints them.
        def card_entries(session_dir)
          JSON.parse(JSON.generate(Bridge::CardStore.saved(session_dir))).map { |entry| entry.except(*LISTING_FIELDS) }
        end

        def unanswerable?(question)
          question["cancelled"] && question["reason"] == "non_interactive"
        end

        def cost_summary(summary)
          return [nil, false] unless summary

          reported = summary.cost_sum.to_f
          estimate = summary.cost_estimate_sum.to_f
          return [reported, false] if reported.positive?
          return [nil, false] unless estimate.positive?

          [estimate, true]
        end

        def json_file(path)
          JSON.parse(File.read(path))
        rescue JSON::ParserError, SystemCallError
          nil
        end

        def tail(text)
          value = text.to_s
          value.length > STDERR_LIMIT ? value[-STDERR_LIMIT, STDERR_LIMIT] : value
        end
      end
    end
  end
end
