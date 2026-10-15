# frozen_string_literal: true

require "digest"
require "fileutils"
require_relative "atomic_file"

module Samagotchi
  # The whole output of a tool call ToolRunner cut (ToolOutputCut's
  # :head_tail_file), saved in the session's folder, tool_output/
  # (sessions/<id>/tool_output/; not output/, the session's reply outbox),
  # so the model reads or rg's it instead of running the command again.
  #
  # The name comes from the content (<tool>-<sha256[0,12]>.txt): the same
  # output gives the same path, so the cut text is the same each time
  # (loop-guard's repeat check, the prompt cache). The files go with the
  # session folder; a session keeps its newest MAX_FILES.
  module ToolOutputFiles
    DIR = "tool_output"
    MAX_FILES = 50

    # Where a saved output is, and its size.
    Saved = Data.define(:path, :bytes, :lines)

    module_function

    # @param session_dir [String] the session's folder (Session.session_dir)
    # @param text [String] the output, saved byte for byte
    # @param tool [String] the tool's name, the file name's start
    # @return [Saved]
    # @raise [SystemCallError] when it can't be written
    def save(session_dir, text, tool:)
      path = planned(session_dir, text, tool: tool).path
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir)
      # Already there (the same output again): newest now, not rewritten.
      # An empty one (cut short) is written again.
      if File.size?(path)
        FileUtils.touch(path)
      else
        AtomicFile.write(path, text)
      end
      prune(dir)
      planned(session_dir, text, tool: tool)
    end

    # Where #save would put +text+, and its size, with nothing written: the
    # cut checks its gap line fits before anything is saved.
    # @return [Saved]
    def planned(session_dir, text, tool:)
      path = File.join(session_dir, DIR, "#{file_tool(tool)}-#{Digest::SHA256.hexdigest(text)[0, 12]}.txt")
      Saved.new(path: path, bytes: text.bytesize, lines: line_count(text))
    end

    # The lines a text has, a last line with no newline counted.
    def line_count(text)
      text.count("\n") + (text.empty? || text.end_with?("\n") ? 0 : 1)
    end

    # A tool name safe in a file name (a plugin's or an MCP tool's).
    def file_tool(tool)
      name = tool.to_s.downcase.gsub(/[^a-z0-9_-]/, "_")
      name.empty? ? "tool" : name
    end

    # Keeps the newest MAX_FILES files of +dir+, by mtime.
    def prune(dir)
      files = Dir.glob(File.join(dir, "*.txt"))
      return if files.size <= MAX_FILES

      files.sort_by { |f| [-File.mtime(f).to_f, f] }.drop(MAX_FILES).each { |f| FileUtils.rm_f(f) }
    end
  end
end
