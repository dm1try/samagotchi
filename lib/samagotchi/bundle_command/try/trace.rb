# frozen_string_literal: true

require "json"
require_relative "../../analytics_file"
require_relative "../../session_metrics"

module Samagotchi
  class BundleCommand
    module Try
      Trace = Data.define(
        :session_id, :exit_code, :answer, :tools, :notices, :cards, :questions, :denied,
        :interactive_blocked, :used_memories, :tokens, :cost, :cost_is_estimate, :model, :sandbox, :stderr_tail
      )

      class TraceReader
        DENIAL_TEXT = "No one to approve it (non-interactive run)."
        SESSION_ID = /\A[A-Za-z0-9_-]+\z/
        STDERR_LIMIT = 4000

        def initialize(state_home:, session_id:)
          @state_home = state_home
          @session_id = session_id if session_id.to_s.match?(SESSION_ID)
        end

        def read(exit_code:, answer:, stderr:, sandbox:)
          return empty_trace(exit_code, answer, stderr, sandbox) unless @session_id

          sessions_dir = File.join(@state_home, "samagotchi", "sessions")
          session_path = File.join(sessions_dir, "#{@session_id}.json")
          session_dir = File.join(sessions_dir, @session_id)
          session = json_file(session_path) || {}
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
                                                                  prompt: summary&.prompt_sum || 0, completion: summary&.completion_sum || 0
                                                                },
            cost: cost, cost_is_estimate: estimate, model: session["model_name"], sandbox: sandbox,
            stderr_tail: tail(stderr)
          )
        end

        private

        def empty_trace(exit_code, answer, stderr, sandbox)
          Trace.new(session_id: nil, exit_code: exit_code, answer: answer.to_s, tools: [], notices: [], cards: [],
                    questions: [], denied: [], interactive_blocked: false, used_memories: [], tokens: {
                      prompt: 0, completion: 0
                    }, cost: nil, cost_is_estimate: false, model: nil, sandbox: sandbox, stderr_tail: tail(stderr))
        end

        def tools(messages, analytics)
          calls = messages.flat_map do |message|
            next [] unless %w[model assistant].include?(message["role"])

            Array(message["tool_calls"]).select { |call| call.is_a?(Hash) }
          end
          records = Array(analytics["tool_records"]).select { |record| record.is_a?(Hash) }
                                                    .sort_by { |record| [record["iteration"].to_i, record["call_index"].to_i] }
          tool_responses = messages.select { |message| %w[tool_response tool].include?(message["role"]) }
          denied = []
          rows = records.each_with_index.map do |record, index|
            call = calls[index] || {}
            id = call["id"]
            response = tool_responses.find { |message| message["tool_call_id"] == id } if id
            response ||= tool_responses[index]
            is_denied = response && response["content"].to_s.include?(DENIAL_TEXT)
            denied << (index + 1) if is_denied
            {
              index: index + 1,
              name: record["called_as"] || record["tool"] || call_name(call),
              args: argument_text(call),
              status: is_denied ? "denied" : record["status"].to_s,
              duration_ms: record["duration_ms"].to_i
            }
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

        def card_entries(session_dir)
          data = json_file(File.join(session_dir, "cards.json"))
          entries = data.is_a?(Hash) ? data["entries"] : []
          Array(entries).select { |entry| entry.is_a?(Hash) }
        end

        def unanswerable?(question)
          question["cancelled"] && question["reason"] == "non_interactive"
        end

        def cost_summary(summary)
          return [nil, false] unless summary

          reported = summary.cost_sum.to_f
          estimate = summary.cost_estimate_sum.to_f
          return [reported, false] if reported.positive? || !estimate.positive?

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
