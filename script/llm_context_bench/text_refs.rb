# frozen_string_literal: true

require "json"

module LLMContextBench
  # The lexical proxies the context-edit spike scored with (its common.py):
  # what a tool call targets (the paths it reads or edits, the command it
  # runs) and which identifiers a text holds. Lenient on purpose: a
  # basename mention counts.
  module TextRefs
    PATH_RE = %r{(?:[\w.-]+/)+[\w.-]+\.\w{1,5}|\b[\w-]+\.(?:rb|md|js|ts|py|json|yml|yaml|css|html|sh|swift|toml|erb)\b}
    IDENT_RE = /\b(?:[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+|[a-z][a-z0-9]*(?:_[a-z0-9]+)+|[A-Z][A-Za-z0-9]+(?:::[A-Z][A-Za-z0-9]+)+)\b/
    # Identifiers shorter than this are too common to count.
    MIN_IDENT = 8
    FILE_TOOLS = %w[read write edit].freeze

    # What a call targets: its paths and its command (execute's), nil for
    # none. Paths are #normalize'd against +projects+.
    Target = Data.define(:keys, :command) do
      def touches?(other)
        keys.intersect?(other.keys) || (!command.nil? && command == other.command)
      end
    end

    module_function

    # Chars/4, the spike's estimate (it undercounts mostly-code contexts by
    # about 1.25x). A non-String is counted as its JSON.
    def tokens(value)
      return 0.0 if value.nil?

      (value.is_a?(String) ? value : JSON.generate(value)).length / 4.0
    end

    # +path+ relative to its project: without a leading "<projects>/<name>/"
    # (+projects+ the folder the session's project sits in, so a sibling
    # worktree's path reads the same) and without leading dots and slashes.
    def normalize(path, projects: nil)
      path = path.to_s
      path = path.sub(%r{\A#{Regexp.escape(projects)}/[^/]+/}, "") if projects && !projects.empty?
      path.sub(%r{\A[./]+}, "")
    end

    # @param args [Hash] the call's arguments, string keys
    # @return [Target]
    def target(name, args, projects: nil)
      args = {} unless args.is_a?(Hash)
      keys = []
      command = nil
      if FILE_TOOLS.include?(name)
        path = normalize(args["path"] || args["file_path"], projects: projects)
        keys << path unless path.empty?
      elsif name == "execute"
        command = args["command"].to_s.strip
        keys.concat(command.scan(PATH_RE).map { |found| normalize(found, projects: projects) })
      end
      Target.new(keys: keys.reject(&:empty?).uniq, command: command)
    end

    # The paths and long identifiers +text+ mentions.
    # @return [Set<String>]
    def idents(text, projects: nil)
      text = text.to_s
      found = Set.new(text.scan(PATH_RE).map { |path| normalize(path, projects: projects) })
      text.scan(IDENT_RE).each { |ident| found << ident if ident.length >= MIN_IDENT }
      found
    end
  end
end
