# frozen_string_literal: true

require_relative "memory_paths"

module Samagotchi
  # The files whose text goes into the system prompt as they are
  # (SystemPrompt): which AGENTS.md files a cwd loads, and how a file
  # becomes a prompt section.
  module PromptFiles
    AGENTS_FILE = "AGENTS.md"

    module_function

    # The AGENTS.md files a session in +cwd+ loads, as absolute paths: the
    # cwd's, else the one at the top of its git work tree ([] with neither).
    # @param cwd [String] where the prompt is built (Dir.pwd, not the
    #   session's working directory: /tmp vs /private/tmp would change the
    #   prompt bytes)
    # @return [Array<String>]
    def agents_paths(cwd)
      path = [cwd, MemoryPaths.work_tree_root(cwd)].compact.uniq
                                                   .map { |dir| File.join(dir, AGENTS_FILE) }
                                                   .find { |candidate| File.file?(candidate) }
      path ? [path] : []
    end

    # +path+'s text under +header+ ("<header>\n<text>", stripped); nil when
    # the file is empty or can't be read.
    # @return [String, nil]
    def section(path, header)
      content = File.read(path, encoding: "UTF-8").strip
      return nil if content.empty?

      "#{header}\n#{content}"
    rescue StandardError
      nil
    end
  end
end
