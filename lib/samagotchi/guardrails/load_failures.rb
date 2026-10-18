# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # What failed to load at Engine start: hooks, bundle hook checksums,
    # rule files. A required one makes the gate deny every tool call (a
    # guardrail that silently vanished is the failure this guards against);
    # the rest are only announced.
    class LoadFailures
      # +location+: "path:line" of the first frame of the error inside the
      # bundle that failed (nil when none is), for `chi bundle check`.
      Failure = Struct.new(:what, :reason, :required, :group, :location, keyword_init: true)

      # "path:line" where +error+ was raised inside +dir+ (its first
      # backtrace frame there; a SyntaxError's own file:line), or nil.
      def self.location(error, dir)
        prefix = "#{File.expand_path(dir)}/"
        frame = Array(error.backtrace).find { |line| line.start_with?(prefix) }
        frame ||= error.message.lines.first if error.is_a?(SyntaxError)
        frame&.start_with?(prefix) ? frame[/\A[^:]+:\d+/] : nil
      end

      def initialize
        @list = []
        @mutex = Mutex.new
      end

      # @param what [String] e.g. "hook guard.rb (config)"
      # @param group [Symbol, nil] what loads it again (#drop): :rules
      # @param location [String, nil] Failure#location
      def add(what, reason, required:, group: nil, location: nil)
        @mutex.synchronize do
          @list << Failure.new(what: what, reason: reason, required: required, group: group, location: location)
        end
      end

      # Forget a group's failures before it loads again.
      def drop(group)
        @mutex.synchronize { @list.reject! { |failure| failure.group == group } }
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
