# frozen_string_literal: true

require_relative "../image_store"

module Samagotchi
  class TerminalUI
    # `@path` in a typed prompt: each token that names an existing image
    # file (by its bytes) becomes one of the turn's images. The prompt text
    # stays as typed; a token that isn't an image (a source file, a missing
    # path, an email address) is just text.
    #
    #   @shot.png  @~/Desktop/a.jpg  @"my shot.png"  @'my shot.png'  @my\ shot.png
    #
    # A bare path takes backslash escapes the way a shell does (what a
    # Finder drag into the terminal types): `\ ` is a space, `\(` a `(`.
    module ImageInput
      # An @ at the start or after whitespace, then a quoted or bare path
      # (a bare one runs on through backslash-escaped whitespace).
      TOKEN_RE = /(?:\A|(?<=\s))@(?:"([^"]+)"|'([^']+)'|((?:\\\s|\S)+))/

      # @return [Array<Hash>] {path:} per image, in order, each path once
      def self.extract(text, cwd: Dir.pwd)
        text.to_s.scan(TOKEN_RE).filter_map do |quoted_double, quoted_single, bare|
          raw = quoted_double || quoted_single || unescape(bare.sub(/(?<!\\)[,.;:!?)\]]+\z/, ""))
          path = expand(raw, cwd)
          path if path && ImageStore.image_file?(path)
        end.uniq.map { |path| { path: path } }
      end

      def self.unescape(bare) = bare.gsub(/\\(.)/m, '\\1')
      private_class_method :unescape

      def self.expand(raw, cwd)
        return nil if raw.empty?

        File.expand_path(raw, cwd)
      rescue ArgumentError # ~unknown_user
        nil
      end
      private_class_method :expand
    end
  end
end
