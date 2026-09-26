# frozen_string_literal: true

module Samagotchi
  module Plugin
    # What a plugin tool's block returns to hand the model images too
    # (docs/plugins.md, Returning images):
    #
    #   Samagotchi::Plugin::ToolResult.new("took a screenshot", images: [{ path: "/tmp/shot.png" }])
    #   Samagotchi::Plugin::ToolResult.new("two frames", images: [{ bytes: png, name: "frame1.png" }, …])
    #
    # It is the text itself (a String), so everything that reads a tool's
    # text keeps working; #images is what ToolRunner attaches. An entry
    # is {path:} or {bytes:, name:} (raw bytes, not base64); one that isn't
    # becomes an "Error:" line for that image, the rest still go.
    class ToolResult < String
      attr_reader :images

      def initialize(text = "", images: [])
        @images = (images.is_a?(Hash) ? [images] : Array(images)).freeze
        super(text.to_s)
      end
    end
  end
end
