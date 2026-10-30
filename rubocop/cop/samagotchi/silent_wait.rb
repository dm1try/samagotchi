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
      #
      # A Timeout.timeout block is flagged too: around a poll or a pop it is
      # a wait whose timeout names nothing (wait_for, pop!, join!). A hang
      # guard around a call that should simply return carries
      # "# timeout-ok: why".
      #
      #   # bad
      #   Timeout.timeout(2) { queue.pop }
      #
      #   # good
      #   pop!(queue, "the redraw", timeout: 2)
      #   status = Timeout.timeout(10) { Process.wait2(pid) } # timeout-ok: a hang guard: the child exits by itself
      #
      # A statement `thread.join(N)` (a number, the one shape Array#join
      # never takes) is a silent wait too: its N isn't scaled by
      # SPEC_TIME_SCALE, and at the deadline it returns nil, which a
      # statement drops, leaving the thread running into teardown. That
      # includes the last line of an each block, whose value each drops.
      # A join whose nil is fine carries "# wait-ok: why".
      #
      #   # bad
      #   thread.join(2)
      #   threads.each { |t| t.join(5) }
      #
      #   # good
      #   join!(thread, "the watcher")
      #   expect(thread.join(0.1)).to be_nil # its value is checked
      class SilentWait < Base
        MSG = "Use wait_for(what) { … }: a timeout then names what it waited for."
        MSG_TIMEOUT = "A Timeout.timeout names nothing when it fires: wait with wait_for(what), pop! or join!. " \
                      "A hang guard around a call that returns by itself carries \"# timeout-ok: why\"."
        TAG = /#\s*wait-ok:\s*\S/
        TIMEOUT_TAG = /#\s*timeout-ok:\s*\S/
        MSG_JOIN = "A statement join(N) drops its nil at an unscaled deadline: join!(thread, what) waits scaled " \
                   "and names what it waited for."
        EXAMPLE_BLOCKS = %i[it specify example before after around].to_set.freeze
        # Blocks whose body value the call drops.
        EACH_BLOCKS = %i[each each_value each_with_index reverse_each].to_set.freeze
        RESTRICT_ON_SEND = %i[join].freeze

        # @!method numeric_join?(node)
        def_node_matcher :numeric_join?, "({send csend} !nil? :join {int float})"

        # @!method wait_until_block?(node)
        def_node_matcher :wait_until_block?, "(any_block (send {nil? (const {nil? cbase} :SpecWaiting)} :wait_until ...) ...)"

        # @!method timeout_block?(node)
        def_node_matcher :timeout_block?, "(any_block (send (const {nil? cbase} :Timeout) :timeout ...) ...)"

        # @!method expect_true?(node, wait)
        def_node_matcher :expect_true?, "(send (send nil? :expect %1) :to {(send nil? {:be :eq} true) (send nil? :be_truthy)})"

        def on_block(node)
          if timeout_block?(node)
            add_offense(node.send_node, message: MSG_TIMEOUT) unless tagged?(node.first_line, TIMEOUT_TAG)
            return
          end
          return unless wait_until_block?(node)
          return unless silent?(node)
          return if tagged?(node.first_line)

          add_offense(node.send_node)
        end
        alias on_numblock on_block
        alias on_itblock on_block

        def on_send(node)
          return unless numeric_join?(node)
          return unless silent_join?(node)
          return if tagged?(node.first_line)

          add_offense(node, message: MSG_JOIN)
        end
        alias on_csend on_send

        private

        def silent_join?(node)
          return true unless node.value_used?
          return true if last_in_example?(node)

          last_in_each?(node)
        end

        def last_in_each?(node)
          current = node
          current = current.parent while current.parent && passes_value_on?(current.parent, current)
          container = current.parent
          container&.any_block_type? && EACH_BLOCKS.include?(container.method_name) && container.body.equal?(current)
        end

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

        def tagged?(line, tag = TAG)
          processed_source.comments.any? { |comment| [line, line - 1].include?(comment.loc.line) && comment.text.match?(tag) }
        end
      end
    end
  end
end
