# frozen_string_literal: true

require "fileutils"
require_relative "tool_path"

module Samagotchi
  module Tools
    # Writes content to a file, creating parent directories as needed.
    # The path is passed as an XML attribute:
    #   <tool name="write" path="lib/samagotchi/tools/new_tool.rb">content</tool>
    class Write
      NAME        = "write"

      def self.name        = NAME

      def self.call(content, path:)
        path = ToolPath.normalize(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        "Written #{content.bytesize} bytes to #{path}"
      rescue => e
        "Error: #{e.message}"
      end
    end
  end
end
