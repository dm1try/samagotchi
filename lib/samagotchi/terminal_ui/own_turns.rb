# frozen_string_literal: true

module Samagotchi
  class TerminalUI
    # This run's own prompts and commands. Sent prompts are always recorded so
    # only this run's failed prompts can return to the input. With pipe input
    # (+active+), this also tracks turns still open, prompts merged into a
    # running turn, whether input ended, and whether a turn failed, was empty, was removed,
    # or still has an answer display pending. #outcome is what #run returns
    # once those turns finish.
    class OwnTurns
      def initialize(active:)
        @active = active
        @sent = Set.new
        @open = Set.new
        @merged = Set.new
        @input_ended = false
        @failed = false
        @empty = false
        @removed = false
        @display_pending = false
      end

      def sent(enqueued_id)
        @sent << enqueued_id
        @open << enqueued_id if @active
      end

      def sent?(enqueued_id) = @sent.include?(enqueued_id)

      def command_sent(command_id)
        @open << command_id if @active
      end

      def command_ran(command_id) = @open.delete(command_id)

      def merged(enqueued_id)
        @merged << enqueued_id if @open.include?(enqueued_id)
      end

      def ended(enqueued_id, failed:, empty:, display_pending:)
        return unless @active

        ours = @open.include?(enqueued_id) || !@merged.empty?
        @failed = true if ours && failed
        @empty = true if ours && empty
        @display_pending = true if ours && display_pending
        @open.delete(enqueued_id)
        @open.subtract(@merged)
        @merged.clear
      end

      def displayed = (@display_pending = false)

      def prompt_failed
        @failed = true if @active
      end

      def dequeued(enqueued_id, by_us:)
        return false unless @open.delete?(enqueued_id)

        by_us ? (@removed = true) : (@failed = true)
        true
      end

      def end_input = (@input_ended = true)

      def input_ended? = @input_ended

      def pending? = !@open.empty? || @display_pending

      def outcome
        return :turn_failed if @failed
        return :empty_answer if @empty
        return :removed if @removed

        :detached
      end
    end
  end
end
