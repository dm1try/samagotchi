# frozen_string_literal: true

module RuboCop
  module Cop
    module Samagotchi
      # A rescue of StandardError whose fallback is a bare literal drops the
      # error without a trace: a prompt section goes missing for a whole
      # session, a route answers empty, and the debug log says nothing.
      # Degrade.call(area, event, fallback:) { … } keeps the fallback and logs
      # one WARN per process (docs/internals/engine.md, Degrading).
      #
      #   # bad
      #   def notes = File.read(path) rescue nil
      #   begin
      #     load_sections
      #   rescue StandardError
      #     []
      #   end
      #
      #   # good
      #   def notes = Degrade.call(:prompt, "model_notes_unreadable") { File.read(path) }
      #   begin
      #     File.read(path)
      #   rescue Errno::ENOENT # a narrower class: missing is fine
      #     nil
      #   end
      #   peer.close rescue nil # degrade-ok: the client is gone, nothing to report
      #
      # Flagged: a bare `rescue`, a modifier `rescue`, or one naming
      # StandardError, whose body is empty or exactly one of nil, false,
      # true, [], {}, "" or 0. A body that does anything else (logs, calls,
      # assigns, re-raises) isn't. A silence that is right (a client gone,
      # a probe that fails routinely, Log's own internals) carries
      # "# degrade-ok: why" on the rescue's line, the line above or the
      # body's line.
      class SilentRescue < Base
        MSG = "A silent fallback hides the error: use Degrade.call(area, event, fallback:) { … }, " \
              "or tag a silence that is right \"# degrade-ok: why\"."
        TAG = /#\s*degrade-ok:\s*\S/

        # @!method standard_error?(node)
        def_node_matcher :standard_error?, "(const {nil? cbase} :StandardError)"

        def on_resbody(node)
          return unless catches_standard_error?(node)
          return unless silent_body?(node.body)
          return if tagged?(node)

          add_offense(node.loc.keyword)
        end

        private

        def catches_standard_error?(node)
          classes = node.exceptions
          classes.empty? || classes.any? { |klass| standard_error?(klass) }
        end

        def silent_body?(body)
          return true if body.nil?

          case body.type
          when :nil, :false, :true then true # rubocop:disable Lint/BooleanSymbol -- AST node types
          when :array, :hash then body.children.empty?
          when :str then body.value.empty?
          when :int then body.value.zero?
          else false
          end
        end

        def tagged?(node)
          lines = [node.first_line, node.first_line - 1]
          lines << node.body.first_line if node.body
          processed_source.comments.any? { |comment| lines.include?(comment.loc.line) && comment.text.match?(TAG) }
        end
      end
    end
  end
end
