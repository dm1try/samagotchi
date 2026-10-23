# frozen_string_literal: true

module RuboCop
  module Cop
    module Samagotchi
      # A wait that times out must say what it waited for. A wait_until whose
      # value is dropped moves on silently at its deadline, and
      # `expect(wait_until { … }).to be(true)` fails with "expected true, got
      # false", which names nothing. wait_for raises naming its +what+.
      #
      #   # bad
      #   wait_until { File.exist?(path) }
      #   expect(wait_until { done }).to be(true)
      #
      #   # good
      #   wait_for("the file") { File.exist?(path) }
      #   found = wait_until { lookup } # a value the example checks after
      #   wait_until(timeout: 0.5) { idle? } # wait-ok: at most, fine to cut short
      #
      # A wait_until that is the last statement of an example or hook block
      # (it, specify, example, before, after, around), an if's branch or an
      # ensure's body there included, counts as unused: RSpec drops that
      # value. A tag goes on the call's first line or the line above.
      class SilentWait < Base
        MSG = "Use wait_for(what) { … }: a timeout then names what it waited for."
        TAG = /#\s*wait-ok:\s*\S/
        EXAMPLE_BLOCKS = %i[it specify example before after around].to_set.freeze

        # @!method wait_until_block?(node)
        def_node_matcher :wait_until_block?, "(any_block (send {nil? (const {nil? cbase} :SpecWaiting)} :wait_until ...) ...)"

        # @!method expect_true?(node, wait)
        def_node_matcher :expect_true?, "(send (send nil? :expect %1) :to {(send nil? {:be :eq} true) (send nil? :be_truthy)})"

        def on_block(node)
          return unless wait_until_block?(node)
          return unless silent?(node)
          return if tagged?(node.first_line)

          add_offense(node.send_node)
        end
        alias on_numblock on_block
        alias on_itblock on_block

        private

        def silent?(node)
          return true unless node.value_used?
          return true if last_in_example?(node)

          expectation = node.parent&.parent
          !expectation.nil? && expect_true?(expectation, node)
        end

        # The wait's value is the example's (or hook's) value, which RSpec
        # drops: its last statement, through the wrappers that pass a value
        # on (a begin, an if's branch, an ensure's or rescue's body).
        def last_in_example?(node)
          current = node
          current = current.parent while current.parent && passes_value_on?(current.parent, current)
          container = current.parent
          container&.any_block_type? && EXAMPLE_BLOCKS.include?(container.method_name) &&
            container.send_node.receiver.nil? && container.body.equal?(current)
        end

        def passes_value_on?(parent, child)
          case parent.type
          when :begin, :kwbegin then parent.children.last.equal?(child)
          when :if then !parent.condition.equal?(child)
          when :ensure, :rescue then parent.children.first.equal?(child)
          when :resbody then parent.body.equal?(child)
          else false
          end
        end

        def tagged?(line)
          processed_source.comments.any? { |comment| [line, line - 1].include?(comment.loc.line) && comment.text.match?(TAG) }
        end
      end
    end
  end
end
