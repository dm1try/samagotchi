# frozen_string_literal: true

require "open3"
require "timeout"

module Samagotchi
  module Tools
    # Runs an arbitrary shell command and returns stdout, stderr, and exit code.
    # The model can use this to execute Ruby snippets, run RSpec, or any other
    # shell command needed during self-improvement or code assistance.
    #
    # Examples the model can emit:
    #   <tool name="execute">ruby -e 'puts 2 + 2'</tool>
    #   <tool name="execute">bundle exec rspec spec/some_spec.rb --no-color</tool>
    #   <tool name="execute">ruby path/to/script.rb</tool>
    class Execute
      NAME        = "execute"
      DESCRIPTION = "Run a shell command (ruby snippet, rspec, etc.) — returns stdout/stderr/exit."
      TIMEOUT_SEC = 30

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(command)
        command = command.strip
        stdout, stderr, status = Timeout.timeout(TIMEOUT_SEC) { Open3.capture3(command) }
        parts = []
        parts << "stdout:\n#{stdout}" unless stdout.empty?
        parts << "stderr:\n#{stderr}" unless stderr.empty?
        parts << "exit: #{status.exitstatus}"
        parts.join("\n")
      rescue Timeout::Error
        "Error: command timed out after #{TIMEOUT_SEC}s"
      rescue => e
        "Error: #{e.message}"
      end
    end
  end
end
