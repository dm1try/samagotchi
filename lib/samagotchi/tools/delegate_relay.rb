# frozen_string_literal: true

require_relative "../session"
require_relative "../bridge_client"
require_relative "../worker_link"
require_relative "../relay"
require_relative "../guardrails/approval"
require_relative "../guardrails/parent_policy"
require_relative "../log"
require_relative "../question_answer"

module Samagotchi
  # Loaded on first use (a require cycle otherwise; see delegate.rb).
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)

  module Tools
    # A child's approval, met by DelegateWait, reopened as the parent's own
    # (the approval relay): the parent's user answers it in the UI they are
    # in, the child takes the answer after asking the parent's Bridge for it
    # (RelayVerifier), and the parent's model sees only the outcome line.
    # Runs on the parent's turn thread, which blocks in the parent's
    # question flow until the card is answered, dismissed, closed by its
    # watch (the child answered first, or its worker went) or the turn is
    # stopped.
    module DelegateRelay
      # How often the card's watch looks at the child.
      WATCH_EVERY = 0.5

      # How often a wait looks at the parent's other children (a full
      # session listing) for approvals to relay.
      OTHERS_EVERY = 2.0

      # What happened to one relayed approval.
      # @!attribute line [String] the outcome line for the tool result
      # @!attribute stopped [Boolean] the parent's turn was stopped
      Outcome = Struct.new(:line, :stopped, keyword_init: true)

      module_function

      # Kinds a relay may carry.
      HOOK_KIND = "hook"

      # @param relay [#open_question, #relay_desk] Peers#relay
      # @param strategy [Guardrails::ParentPolicy::Strategy] the child's
      #   (ParentPolicy.for_session(child))
      # @return [Boolean] a relay can take this question
      # @param child_id [String, nil] the asking child: a hook's question
      #   already answered on one of this parent's relays
      #   (RelayDesk#settled?) isn't relayed again; an approval is (as before
      #   P4: a refused or undelivered answer is offered again)
      def relayable?(relay, question, strategy:, child_id: nil)
        return false if relay.nil? || !relay?(question, strategy: strategy)
        return true unless child_id && question.kind.to_s == HOOK_KIND

        !relay.relay_desk.settled?(child_id, question.id)
      end

      # Whether a delegate's question goes to the parent's user rather than
      # its model: every approval, and a hook's question the parent can't
      # usefully answer under the child's strategy
      # (Guardrails::ParentPolicy.parent_decides?). The one place that says
      # which kinds the relay carries: the wait (DelegateWait.call), the
      # look at the other children (Others#waiting) and the delegate
      # reports (ChildReports) all ask it.
      def relay?(question, strategy:)
        return false unless question.is_a?(PendingQuestion)

        case question.kind.to_s
        when Guardrails::Approval::KIND then true
        when HOOK_KIND then !Guardrails::ParentPolicy.parent_decides?(question, strategy: strategy)
        else false
        end
      end

      # Relay the child's pending approval and wait until it settles.
      # @param more [Integer] other delegates' approvals waiting behind it
      # @return [Outcome]
      def call(child_id, question, relay:, state_dir:, more: 0)
        child = Session.load(child_id, state_dir: state_dir)
        qid = question.id.to_s
        desk = relay.relay_desk
        relay_id = desk.open(child_id: child_id, child_question_id: qid)
        client = WorkerLink.client(child_id, session_dir: Session.session_dir(child_id, state_dir: state_dir))
        post(client, "opened", relay_id, qid)
        Log.info(:turn, "relay_opened", child: child_id[0, 8], id: qid)

        fields = Relay.card(child, question, relay_id: relay_id, more: more)
        answer = relay.open_question(fields, watch: watch(child_id, qid, state_dir))
        settle(answer, fields, label: label(question), client: client, desk: desk, relay_id: relay_id, qid: qid)
      ensure
        # A relay that failed before it settled closes, so the desk (which
        # prunes only settled ones) keeps none open; a settled one stays.
        desk&.close(relay_id) if relay_id
      end

      # Closes the card when the child's question is no longer pending (it
      # was answered or cancelled there) or its worker is gone.
      def watch(child_id, qid, state_dir)
        lambda do
          unless WorkerLink.resolve(Session.session_dir(child_id, state_dir: state_dir), unlink: false).worker_owned?
            next "child_gone"
          end

          pending = Session.load(child_id, state_dir: state_dir).pending_question
          pending && pending.id.to_s == qid ? nil : "answered_on_child"
        rescue ArgumentError
          "child_gone"
        end
      end

      # Record the parent's answer, tell the child, and say what came of it.
      # @param label [String] the outcome line's start (#label)
      def settle(answer, fields, label:, client:, desk:, relay_id:, qid:)
        if answer.is_a?(Hash) && answer[:error] == "cancelled"
          desk.close(relay_id)
          return closed(answer[:reason].to_s, label, client: client, relay_id: relay_id, qid: qid)
        end

        dismissed = !answer.is_a?(QuestionAnswer)
        by = answer.is_a?(QuestionAnswer) && answer.parent_agent? ? "parent_agent" : "user"
        desk.record(relay_id, selected_indices: dismissed ? [] : answer.selected_indices,
                              freeform: dismissed ? nil : answer.freeform, dismissed: dismissed, by: by)
        response = post(client, "answered", relay_id, qid)
        Outcome.new(line: line(label, delivered(response, answer, fields, dismissed)), stopped: false)
      end

      def closed(reason, label, client:, relay_id:, qid:)
        case reason
        when "answered_on_child" then Outcome.new(line: line(label, "answered on the child"), stopped: false)
        when "child_gone"
          Outcome.new(line: line(label, "not delivered (the child's worker is gone)"), stopped: false)
        else
          # A Stop: the child's question stays open there.
          post(client, "closed", relay_id, qid, reason: "stopped")
          Outcome.new(line: line(label, "still open (your turn was stopped)"), stopped: true)
        end
      end

      # The outcome of an answer the child was told about.
      def delivered(response, answer, fields, dismissed)
        return "not delivered (the child's worker is gone)" unless response

        # The child's Bridge asked for a secret this worker didn't send (one
        # from before the child's chi): not the child's guardrails refusing.
        return "not delivered (#{BridgeSecret::REFUSED})" if response.secret_refused?

        hook = fields[:kind] == HOOK_KIND
        case response.status
        when 200
          # A dismissed hook question: the hook decides what no answer means.
          return dismissed ? "dismissed" : answer.selected.join(", ") if hook

          dismissed ? "dismissed (denied)" : verdict(answer, fields)
        when 409 then "answered on the child"
        when 403
          "refused by the child (a parent agent may not #{hook ? "pick it" : "allow it"}); it waits for the user there"
        else "not delivered (#{response.json&.fetch("error", nil) || response.status})"
        end
      end

      # allowed once / allowed for its session / denied ("why")
      def verdict(answer, fields)
        scopes = Array(fields.dig(:approval, :scopes))
        index = answer.selected_indices.first
        if index && index < scopes.size
          return case scopes[index].to_s
                 when "once" then "allowed once"
                 when "session" then "allowed for the delegate's session"
                 when "repo" then "allowed in this repo or directory"
                 when "rule" then "allowed by rule #{fields.dig(:approval, :rule)}"
                 else "allowed"
                 end
        end

        why = answer.freeform.to_s.strip
        why.empty? ? "denied" : "denied (#{why.inspect})"
      end

      # One relayed question's outcome line: #label → +outcome+.
      def line(label, outcome) = "#{label} → #{outcome}"

      # What an outcome line starts with: "hook question relayed to your
      # user: Cost cap", "approval relayed to your user: execute: git push".
      # @param question [PendingQuestion] the child's
      def label(question)
        "#{question.kind.to_s == HOOK_KIND ? "hook question" : "approval"} relayed to your user: #{what(question)}"
      end

      # What a relayed question is about, as its card has it (Relay.card): a
      # hook's header as the asking hook gave it (kept down a chain: a relay
      # of a relay), else its hook; an approval's call (#what_text).
      # @param question [PendingQuestion] the child's
      def what(question)
        return what_text(symbolized(question.approval)) unless question.kind.to_s == HOOK_KIND

        inner = symbolized(question.relay, nil)
        header = (inner ? inner[:header] : question.header).to_s
        header.empty? ? question.hook.to_s : header
      end

      def symbolized(value, none = {})
        value.is_a?(Hash) ? Relay.deep_symbolize(value) : none
      end

      # execute: git push origin main
      def what_text(facts)
        facts = {} unless facts.is_a?(Hash)
        tool = facts[:label] || facts[:tool] || "tool"
        what = facts[:command] || Array(facts[:paths]).join(", ")
        what = facts[:args].to_s if what.to_s.empty?
        what.to_s.empty? ? tool.to_s : "#{tool}: #{what}"
      end

      # The parent's other running children, while it waits on one (D2):
      # their approvals are relayed too, oldest first, one card at a time.
      # Each outcome is kept for that child's next DelegateWait result
      # (DelegateWait.relayed_outcomes). Every question is relayed once per
      # wait.
      class Others
        # The kinds of question a relay may carry (DelegateRelay.relay? decides).
        KINDS = [Guardrails::Approval::KIND, HOOK_KIND].freeze

        # @param parent_id [String]
        # @param except [String] the child waited on (its own approvals come
        #   through ReplyWait)
        # @param on_outcome [#call] (child_id, Outcome)
        def initialize(parent_id:, except:, relay:, state_dir:, on_outcome:, every: OTHERS_EVERY)
          @parent_id = parent_id
          @except = except
          @relay = relay
          @state_dir = state_dir
          @on_outcome = on_outcome
          @every = every
          @done = {}
          @next_at = 0.0
        end

        # Relay the oldest waiting approval of another child, if any (a
        # ReplyWait interject). Throttled to one look every +every+ s.
        def poll
          return if monotonic < @next_at

          @next_at = monotonic + @every
          waiting = self.waiting
          return if waiting.empty?

          child_id, question = waiting.first
          @done[question.id.to_s] = true
          outcome = DelegateRelay.call(child_id, question, relay: @relay, state_dir: @state_dir, more: waiting.size - 1)
          @on_outcome.call(child_id, outcome)
          # The next one, if any, right after.
          @next_at = 0.0
        end

        # Other children's approvals not yet relayed in this wait.
        # @return [Integer]
        def count = waiting.size

        # @return [Array<Array(String, PendingQuestion)>] [child id, pending question],
        #   oldest question first
        def waiting
          rows = SessionManager.children_of(@parent_id, state_dir: @state_dir).select do |row|
            row[:id] != @except && KINDS.include?(row[:waiting].to_s) && !@done[row[:waiting_id].to_s]
          end
          rows.filter_map do |row|
            child = Session.load(row[:id], state_dir: @state_dir)
            pending = child.pending_question
            next nil unless pending && pending.id.to_s == row[:waiting_id].to_s
            next nil unless DelegateRelay.relayable?(@relay, pending, strategy: Guardrails::ParentPolicy.for_session(child),
                                                                      child_id: row[:id])

            [row[:id], pending]
          rescue ArgumentError
            nil
          end.sort_by { |_, pending| pending.created_at.to_s }
        end

        private

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # @return [BridgeClient::Response, nil] nil when the child's worker
      #   can't be reached
      def post(client, action, relay_id, qid, **extra)
        return nil unless client

        client.relay(action: action, relay_id: relay_id, question_id: qid, **extra)
      rescue SystemCallError, IOError => e
        Log.info(:turn, "relay_post_failed", action: action, error: e.class.name)
        nil
      end
    end
  end
end
