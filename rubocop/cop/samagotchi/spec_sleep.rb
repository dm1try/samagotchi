# frozen_string_literal: true

module RuboCop
  module Cop
    module Samagotchi
      # A spec waits *for* something, never a fixed time: a sleep that
      # settles state is too short on a slow runner and too long on a fast
      # one. A sleep that is the behaviour under test (slowness, holding a
      # connection, separating mtimes) says so with a tag on its line or the
      # line above, with a reason:
      #
      #   # bad
      #   sleep 0.1
      #
      #   # good
      #   wait_for("the task to end") { record.status != "running" }
      #   sleep 0.2 # sleep-ok: the server is slow on purpose
      #
      # A sleep in a shell string ("sleep 30") isn't a Ruby call: not flagged.
      class SpecSleep < Base
        MSG = "A sleep that waits for something: use wait_for(what) { … }, loop rounds, or a join. " \
              'A sleep that is the behaviour (slowness, holding, mtime) carries "# sleep-ok: why".'
        TAG = /#\s*sleep-ok:\s*\S/
        RESTRICT_ON_SEND = %i[sleep].freeze

        # @!method sleep_call?(node)
        def_node_matcher :sleep_call?, "(send {nil? (const {nil? cbase} :Kernel)} :sleep ...)"

        def on_send(node)
          return unless sleep_call?(node)
          return if tagged?(node.first_line)

          add_offense(node)
        end

        private

        def tagged?(line)
          processed_source.comments.any? { |comment| [line, line - 1].include?(comment.loc.line) && comment.text.match?(TAG) }
        end
      end
    end
  end
end
