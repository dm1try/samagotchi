# frozen_string_literal: true

require "minitest"
require_relative "../testing"

module Samagotchi
  module Testing
    # The bundle test kit in Minitest (EXPERIMENTAL, docs/plugins.md): a
    # test case with Helpers (load_bundle, shipped_bundle, sandbox), each
    # test in its own sandbox, its bundles shut down after it.
    #
    #   class MyBundleTest < Samagotchi::Testing::Case
    #     def test_denies = assert load_bundle(__dir__ + "/..").tool_call({ name: "execute", content: "rm -rf /" }).deny?
    #   end
    class Case < Minitest::Test
      include Helpers

      def before_setup
        super
        enter_sandbox
      end

      def after_teardown
        leave_sandbox
        super
      end
    end
  end
end
