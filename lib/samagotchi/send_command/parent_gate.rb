# frozen_string_literal: true

require_relative "../session"
require_relative "../session_chain"
require_relative "../session_commands"
require_relative "../parent_answers_command"
require_relative "../turn_flow"
require_relative "../guardrails/parent_approvals"
require_relative "../guardrails/parent_policy"

module Samagotchi
  class SendCommand
    # What a parent agent's line may do, checked before chi send sends it
    # (before a --new session is created too), against each target's own
    # parent_answers: a --new session's --parent-answers, a --continues
    # link's previous session's (the link keeps it), each id's.
    #
    # A parent agent's /continue yes is chi answer --option Continue by
    # another route: held to guardrails.parent_answers tightened by each
    # target's own (#continue_refusal), and sent marked as chi answer's
    # (SendCommand#client_id_for) so the worker checks it again. A
    # /parent-answers line never loosens a target's own value (#loosens?):
    # only a user at a UI does, and the worker refuses it too. Tightening
    # goes.
    class ParentGate
      # @param options [Hash] chi send's parsed options (:new, :continues,
      #   :parent_answers, :ids)
      def initialize(options, state_dir:)
        @options = options
        @state_dir = state_dir
      end

      # A /continue yes (or bare /continue) from a parent agent's process.
      def self.parent_continue?(prompt) = TurnFlow.continue_yes?(prompt) && Guardrails::ParentApprovals.parent_process?

      # @return [String, nil] the first target's refusal of a parent's
      #   /continue yes; nil for any other line, or when none refuses
      def continue_refusal(prompt)
        return nil unless self.class.parent_continue?(prompt)

        target_values.each do |value|
          strategy = Guardrails::ParentPolicy.effective(value)
          refusal = Guardrails::ParentPolicy.continue_refusal(strategy: strategy)
          return refusal if refusal
        end
        nil
      end

      # Whether +prompt+ is a /parent-answers line that loosens a target's
      # own value.
      def loosens?(prompt)
        SessionCommands.builtin_registry.lookup(prompt)&.id == :parent_answers &&
          target_values.any? { |value| ParentAnswersCommand.loosens?(prompt, value) }
      end

      private

      # The targets' own parent_answers values. An id that doesn't resolve
      # is skipped (SendCommand#resolve reports it later); none left is
      # config.yml's alone ([nil]).
      def target_values
        @target_values ||= if @options[:new] && !@options[:continues]
                             [@options[:parent_answers]]
                           else
                             sessions = if @options[:new]
                                          [target_session { SessionChain.resolve(@options[:continues], state_dir: @state_dir) }]
                                        else
                                          @options[:ids].map { |given| target_session { Session.resolve_id(given, state_dir: @state_dir) } }
                                        end
                             values = sessions.compact.map(&:parent_answers)
                             values.empty? ? [nil] : values
                           end
      end

      # The session the block's id names, or nil when there is none.
      def target_session
        Session.load(yield, state_dir: @state_dir)
      rescue ArgumentError
        nil
      end
    end
  end
end
