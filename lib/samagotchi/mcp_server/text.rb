# frozen_string_literal: true

require_relative "../parent_report"
require_relative "../session_access/ask"

module Samagotchi
  module McpServer
    # The tools' words: each outcome as a tools/call result, text the
    # host's model can act on plus the same facts as structuredContent
    # (docs/mcp-server.md, "What a result says"). A refusal or a turn that
    # ended without a reply is isError with chi's own words.
    module Text
      INSTRUCTIONS = <<~TEXT.strip
        chi (Samagotchi) is an agent harness; these tools drive its sessions on this machine (or on the chi web they reach).
        chi_sessions lists them. chi_ask sends a message to a session as its own turn and waits for the answer.
        A result that says "Still running" carries a token: call chi_wait with it until the answer comes.
        A result that says a question waits: call chi_answer with session, question_id and option (or text).
      TEXT

      RUNNING = "Still running. Call chi_wait with this token to keep waiting."
      ANSWER_HINT = "Call chi_answer with session, question_id and option (or text)."
      # chi_ask's refusal of a shell line or a session command (an MCP
      # tool is approved once: narrower than chi send).
      COMMAND_REFUSED = "chi_ask takes a message for the model, not a command: run the command in the session's own UI"

      module_function

      # A host may hand its model the structuredContent alone (Claude Code
      # 2.1.330 does when there is one), so it carries the words too:
      # +text+, unless +words+ is false (the sessions' rows say it all).
      # @return [Hash] a tools/call result
      def result(text, structured, error: false, words: true)
        structured = { **structured, text: text } if words && !structured.key?(:text) && !structured.key?(:detail)
        { content: [{ type: "text", text: text }], structuredContent: structured, isError: error }
      end

      def error(text, **structured) = result(text, { status: "error", **structured, detail: text }, error: true)

      # A wait's ReplyWait::Result for +session_id+.
      # @param token [String, nil] the next wait's, for :timeout
      # @param strategy [Guardrails::ParentPolicy::Strategy] what a parent
      #   may pick there (the backend's parent_strategy)
      # @param extra [Hash] more structured keys (answered_here: false)
      def wait_result(result, session_id:, token:, strategy:, extra: {})
        base = { session_id: session_id, **extra }
        case result.status
        when :done
          text = result.text.to_s
          text = "(the turn ended with an empty reply)" if text.strip.empty?
          result(text, { status: "done", **base, turn_id: result.turn_id }.compact)
        when :timeout then result("#{RUNNING}\ntoken: #{token}", { status: "running", **base, token: token })
        when :waiting_for_answer then question(result.question, session_id: session_id, strategy: strategy, extra: extra)
        when :no_reply then error(no_reply(result, strategy), **base, outcome: result.outcome)
        when :error then error("the worker failed: #{result.text}", **base)
        when :worker_gone then error("the worker is gone; ask again to start a fresh one", **base)
        when :stopped then error("the session was stopped", **base)
        when :canceled then error("the wait was cut short (chi is stopping); call chi_wait again", **base, token: token)
        else error("still running (#{result.status}); call chi_wait again", **base, token: token)
        end
      end

      # A pending question (a PendingQuestion) as a host's model answers it.
      def question(pending, session_id:, strategy:, extra: {})
        q = ParentReport.question(pending, strategy: strategy)
        allowed = q[:allowed_options] || q[:options]
        lines = ["A question waits in session #{session_id} (#{q[:kind]}):"]
        lines << q[:header] if q[:header]
        lines << q[:text].strip
        q[:options].each_with_index { |option, i| lines << "  #{i + 1}. #{option}" }
        lines << "A parent may pick: #{allowed.join(", ")} (the rest is your user's)." if allowed != q[:options]
        lines << "Several options may be picked." if q[:multi_select]
        lines << "Free text is taken too." if q[:allow_freeform]
        lines << "question_id: #{q[:id]}"
        lines << ANSWER_HINT
        structured = { status: "waiting_for_answer", session_id: session_id, **extra,
                       question: { id: q[:id], kind: q[:kind], text: q[:text], options: q[:options],
                                   multi_select: q[:multi_select] },
                       allowed: allowed }
        result(lines.join("\n"), structured)
      end

      # How a turn that left no reply ended (ParentReport's words; a turn
      # out of iterations points at chi_ask's /continue yes).
      def no_reply(result, strategy)
        line = ParentReport.no_reply_line(result, strategy: strategy)
        return line unless result.outcome == "exhausted"

        ran_out = "the turn ran out of iterations#{" (#{result.limit} steps)" if result.limit} before it answered"
        if (strategy || Guardrails::ParentPolicy.current).allow?(Guardrails::ParentPolicy::SPEND)
          "#{ran_out}; chi_ask with \"/continue yes\" continues it, a message drops it"
        else
          "#{ran_out}; continuing it is up to your user, a message drops it"
        end
      end

      # An Ask::Refused in its own words.
      def refused(refused)
        base = { session_id: refused.session_id }.compact
        case refused.kind
        when :busy then busy(refused)
        when :unknown then error(refused.message.to_s, **base, reason: "unknown")
        when :undelivered then error(refused.result.refusal_text, **base, reason: "undelivered")
        when :canceled then error("chi is stopping; ask again", **base, reason: "canceled")
        else error(refused.message.to_s, **base, reason: refused.kind.to_s)
        end
      end

      def busy(refused)
        busy = refused.busy
        if busy.error == "waiting" && busy.question
          words = "a question waits for an answer first"
          text = "#{words}:\n#{question(busy.question, session_id: refused.session_id, strategy: busy.strategy)[:content].first[:text]}"
          return error(text, session_id: refused.session_id, reason: "waiting", question_id: busy.question.id.to_s)
        end

        error("a turn is running: wait for it, then ask again", session_id: refused.session_id, reason: busy.error)
      end

      # A line the worker ran as a session command: no reply comes.
      def ran(session_id) = result("Done: the line ran as a session command; no reply comes.",
                                   { status: "command", session_id: session_id })

      # chi_sessions' rows (SessionRow).
      def sessions(rows)
        listed = rows.map do |row|
          { id: row.id, title: row.title || row.desc, status: row.status, waiting: row.waiting, project: row.project,
            updated_at: row.updated_at }
        end
        text = if listed.empty?
                 "No sessions."
               else
                 listed.map do |row|
                   bits = [row[:id], row[:title].to_s, row[:status].to_s]
                   bits << "a #{row[:waiting]} waits" if row[:waiting]
                   bits << row[:project] if row[:project]
                   bits.join(" · ")
                 end.join("\n")
               end
        result(text, { sessions: listed }, words: false)
      end
    end
  end
end
