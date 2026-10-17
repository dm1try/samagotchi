# frozen_string_literal: true

require_relative "bundle"
require_relative "fake_http"
require_relative "sandbox"
require_relative "waiting"

module Samagotchi
  module Testing
    # For any test framework: load bundles that #shutdown_bundles stops,
    # in the test's sandbox. The RSpec and Minitest adapters call
    # #enter_sandbox before each test and #leave_sandbox after it.
    module Helpers
      include Waiting

      # The bundle in +dir+ (Bundle.load), shut down after the test.
      def load_bundle(dir, **) = remember_bundle(Bundle.load(dir, sandbox: sandbox, **))

      # A shipped bundle by name (Bundle.shipped), shut down after the test.
      def shipped_bundle(name, **) = remember_bundle(Bundle.shipped(name, sandbox: sandbox, **))

      # This test's sandbox (entered on first use when no adapter did).
      # @return [Sandbox]
      def sandbox = (@samagotchi_sandbox ||= Sandbox.enter)

      def enter_sandbox = sandbox

      # Shut the loaded bundles down and leave the sandbox, then say what
      # no stub answered: the adapters fail the test with it (only a test
      # that passed: a failure of its own is not hidden). The requests are
      # collected before the shutdown, and nothing is raised before the
      # cleanup is done.
      # @return [Array<FakeHttp::Request>] the ctx.http requests no stub
      #   answered, of every bundle the test loaded
      def leave_sandbox
        unmatched = (@samagotchi_bundles || []).flat_map { |bundle| bundle.http.unmatched }
        shutdown_bundles
        @samagotchi_sandbox&.leave
        @samagotchi_sandbox = nil
        unmatched
      end

      def shutdown_bundles
        (@samagotchi_bundles || []).reverse_each(&:shutdown)
        @samagotchi_bundles = []
      end

      private

      def remember_bundle(bundle)
        (@samagotchi_bundles ||= []) << bundle
        bundle
      end
    end
  end
end
