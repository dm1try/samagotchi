# frozen_string_literal: true

module Samagotchi
  # The optional commonmarker gem (the Gemfile's :markdown group), loaded on
  # first need by whoever parses an answer's markdown: the web's render
  # (Web::MarkdownRenderer) and the worker's block fixes (BlockFix.locate), so
  # both read a block the same way. Loading it once is enough for the process.
  module MarkdownParser
    @mutex = Mutex.new
    @available = nil

    class << self
      # Whether ::Commonmarker is loaded (it is required on the first call).
      def available?
        @mutex.synchronize do
          return @available unless @available.nil?

          @available = begin
            require "commonmarker"
            true
          rescue LoadError
            false
          end
        end
      end
    end
  end
end
