# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # What failed to load at Engine start: hooks, bundle hook checksums,
    # rule files. A required one makes the gate deny every tool call (a
    # guardrail that silently vanished is the failure this guards against);
    # the rest are only announced.
    class LoadFailures
      Failure = Struct.new(:what, :reason, :required, keyword_init: true)

      def initialize
        @list = []
        @mutex = Mutex.new
      end

      # @param what [String] e.g. "hook guard.rb (config)"
      def add(what, reason, required:)
        @mutex.synchronize { @list << Failure.new(what: what, reason: reason, required: required) }
      end

      def list = @mutex.synchronize { @list.dup }
      def any? = !list.empty?
      def required = list.select(&:required)

      # A core check: deny every call while a required guardrail is missing.
      def check(verdict)
        first = required.first
        return verdict unless first

        verdict.deny!("required guardrail #{first.what} failed to load: #{first.reason}",
                      rule: "guardrail-load", source: "core", decided_by: "core")
      end

      # One line for the UIs, or nil.
      def message
        items = list
        return nil if items.empty?

        text = items.map { |f| "#{f.what} failed to load (#{f.reason})" }.join("; ")
        text += ". Every tool call is denied until it is fixed" if items.any?(&:required)
        text
      end
    end
  end
end
