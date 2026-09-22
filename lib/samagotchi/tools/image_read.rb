# frozen_string_literal: true

require "base64"
require "json"
require_relative "tool_path"

module Samagotchi
  module Tools
    # Reads an image file and returns its base64 data URI for use in multimodal
    # LLM requests. The agent can call this tool when a user asks it to "see" an
    # image or screenshot.
    #
    # Examples the model can emit:
    #   <tool name="image_read">{"path": "/Users/dmitrydedov/Desktop/screenshot.png"}</tool>
    class ImageRead
      NAME        = "image_read"
      DESCRIPTION = 'Read an image file and return its base64 data URI for use in multimodal LLM requests. Supports PNG, JPG, JPEG, GIF, and WebP formats.'

      SUPPORTED_EXTENSIONS = %w[.png .jpg .jpeg .gif .webp].freeze
      MIME_TYPES = {
        ".png"  => "image/png",
        ".jpg"  => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".gif"  => "image/gif",
        ".webp" => "image/webp"
      }.freeze

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(path)
        path = ToolPath.normalize(path)
        return "Error: path is required" if path.empty?

        unless File.exist?(path)
          return "Error: file not found: #{path}"
        end

        unless File.file?(path)
          return "Error: not a file: #{path}"
        end

        unless File.readable?(path)
          return "Error: permission denied: #{path}"
        end

        ext = File.extname(path).downcase
        unless SUPPORTED_EXTENSIONS.include?(ext)
          return "Error: unsupported image format '#{ext}'. Supported: #{SUPPORTED_EXTENSIONS.join(', ')}"
        end

        mime_type = MIME_TYPES[ext]
        image_data = File.binread(path)
        base64_data = Base64.strict_encode64(image_data)

        {
          uri: "data:#{mime_type};base64,#{base64_data}",
          mime_type: mime_type,
          size_bytes: image_data.bytesize
        }
      rescue => e
        "Error: #{e.class}: #{e.message}"
      end
    end
  end
end
