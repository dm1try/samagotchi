# frozen_string_literal: true

require_relative "tools/read"
require_relative "tools/write"
require_relative "tools/edit"

module Samagotchi
  # A ref to the file a read/write/edit call touched, for a UI to trace it
  # (the web opens it in this machine's editor): its absolute path (the
  # call's path against the session's cwd) and the lines the call named (a
  # range read or a range edit). A ref is a kind and a target; what a click
  # does is the UI's (refs.js keeps the actions per kind), so nothing here
  # names an editor.
  FileRef = Data.define(:path, :line, :end_line) do
    # @return [Hash] {kind: "file", path:, line:, end_line:}, the lines only
    #   when there are some
    def to_h = { kind: FileRef::KIND, **super.compact }
  end

  class FileRef
    KIND = "file"

    TOOLS = [Tools::Read::NAME, Tools::Write::NAME, Tools::Edit::NAME].freeze

    # @param cwd [String, nil] the session's working directory; without one
    #   a relative path gets no ref (an absolute or ~ path still does)
    # @return [FileRef, nil] nil for a tool that isn't a file tool and for a
    #   path it can't place. +line+: the call's start_line when positive;
    #   +end_line+: its end_line, only when past +line+.
    def self.for(tool_name, call, cwd:)
      return nil unless TOOLS.include?(tool_name) && call.is_a?(Hash)

      path = absolute((tool_name == Tools::Read::NAME ? call[:content] : call[:path]).to_s.strip, cwd)
      return nil unless path

      line = positive(call[:start_line])
      end_line = line && positive(call[:end_line])
      new(path: path, line: line, end_line: end_line && end_line > line ? end_line : nil)
    end

    def self.absolute(raw, cwd)
      return nil if raw.empty?
      return File.expand_path(raw) if raw.start_with?("/", "~")
      return nil if cwd.to_s.empty?

      File.expand_path(raw, cwd)
    rescue ArgumentError
      # ~user for a user that doesn't exist.
      nil
    end
    private_class_method :absolute

    def self.positive(value)
      number = Integer(value.to_s.strip, exception: false)
      number&.positive? ? number : nil
    end
    private_class_method :positive
  end
end
