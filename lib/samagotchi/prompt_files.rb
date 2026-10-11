# frozen_string_literal: true

require_relative "memory_paths"

module Samagotchi
  # The files whose text goes into the system prompt as they are
  # (SystemPrompt): which AGENTS.md files a cwd loads, and how a file
  # becomes a prompt section.
  module PromptFiles
    AGENTS_FILE = "AGENTS.md"

    AGENTS_HEADER = "Project specific description:"

    # A file's text as the prompt carries it: +path+ absolute, +text+ the
    # section with its header.
    Section = Data.define(:path, :text)

    module_function

    # The AGENTS.md files a session in +cwd+ loads, as absolute paths,
    # outermost first: inside a git work tree every one from its top (a
    # linked worktree's own checkout) down to the cwd; outside a repository
    # only the cwd's ([] with none).
    # @param cwd [String] where the prompt is built (Dir.pwd, not the
    #   session's working directory: /tmp vs /private/tmp would change the
    #   prompt bytes)
    # @return [Array<String>]
    def agents_paths(cwd)
      chain_dirs(cwd).map { |dir| File.join(dir, AGENTS_FILE) }.select { |path| File.file?(path) }
    end

    # The sections of the AGENTS.md chain (#agents_paths) with text: the
    # first keeps the plain header (a one-file session's prompt is as it
    # always was), each further one names its directory relative to the
    # work tree top ("Project specific description for pkg/:").
    # @return [Array<Section>]
    def agents_sections(cwd)
      top = MemoryPaths.work_tree_root(cwd)
      sections = []
      agents_paths(cwd).each do |path|
        dir = File.dirname(path)
        header = sections.empty? ? AGENTS_HEADER : "Project specific description for #{relative_dir(dir, top) || dir}/:"
        text = section(path, header)
        sections << Section.new(path: path, text: text) if text
      end
      sections
    end

    # The directories whose AGENTS.md a session in +cwd+ reads, outermost first.
    def chain_dirs(cwd)
      cwd = File.expand_path(cwd)
      top = MemoryPaths.work_tree_root(cwd)
      return [cwd] unless top

      rel = relative_dir(cwd, top)
      return [top] if rel == "."
      # A cwd the walk up didn't reach from (not expected): only its own and the top's.
      return [top, cwd] if rel.nil?

      parts = rel.split("/")
      [top] + parts.each_index.map { |i| File.join(top, *parts[0..i]) }
    end

    # +dir+ relative to +top+ ("." for the top itself), nil when it isn't under it.
    def relative_dir(dir, top)
      return "." if dir == top

      prefix = top.end_with?("/") ? top : "#{top}/"
      dir.start_with?(prefix) ? dir.delete_prefix(prefix) : nil
    end

    # How a prompt file is named in the prompt and /stats: relative to the
    # work tree +top+ when inside it, else with ~ for the home directory.
    # @return [String]
    def display_path(path, top:)
      rel = top && relative_dir(path, top)
      return rel if rel && rel != "."

      home = Dir.home
      path.start_with?("#{home}/") ? "~#{path.delete_prefix(home)}" : path
    rescue ArgumentError
      path
    end

    # A chi --append-system-prompt value: [absolute path, nil], or
    # [absolute path, the reason it can't be used].
    # @param cwd [String] the shell's cwd the value is relative to
    # @return [Array(String, String)]
    def check_cli_file(value, cwd: Dir.pwd)
      begin
        path = File.expand_path(value.to_s, cwd)
      rescue ArgumentError
        # A quoted "~nosuchuser/x" reaches chi unexpanded.
        return [value.to_s, "no such user"]
      end
      reason = if !File.exist?(path) then "no such file"
               elsif !File.file?(path) then "not a file"
               elsif !File.readable?(path) then "can't be read"
               end
      [path, reason]
    end

    # Text this long goes into every request: chi warns once, at start.
    LARGE_CHARS = 32_000

    # The number of chars of +path+ when above LARGE_CHARS, else nil.
    # @return [Integer, nil]
    def large_size(path)
      chars = File.read(path, encoding: "UTF-8").length
      chars > LARGE_CHARS ? chars : nil
    rescue StandardError
      nil
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
