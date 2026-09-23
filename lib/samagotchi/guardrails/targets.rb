# frozen_string_literal: true

require_relative "../tools/tool_path"
require_relative "../tools/memory"

module Samagotchi
  module Guardrails
    # What a tool call acts on, resolved the way the tools resolve it: the
    # shell command, absolute paths (against Dir.pwd, as the file tools have
    # no cwd:), the directory a command runs in, its repo root, and whether
    # a path leaves the repo (the cwd when there is no repo).
    class Targets
      SHELL_TOOLS = %w[execute task_create].freeze
      PATH_TOOLS = %w[write edit read memory_write].freeze

      attr_reader :tool, :command, :paths, :cwd, :repo_root

      # @param call [Hash] the parsed tool call
      # @param context [Context]
      # @param model_key [String, nil] for a memory_write model overlay
      def self.for(call, context, model_key: nil)
        tool = call[:name].to_s
        base = context.cwd
        command = nil
        paths = []
        cwd = base
        case tool
        when *SHELL_TOOLS
          command = call[:content].to_s
          given = call[:cwd].to_s.strip
          cwd = File.expand_path(given, base) unless given.empty?
        when "write", "edit"
          paths << absolute(call[:path], base)
        when "read"
          paths << absolute(call[:content], base)
        when "memory_write"
          paths << memory_path(call, model_key)
        end
        new(tool: tool, command: command, paths: paths.compact, cwd: cwd, repo_root: context.repo_root(cwd))
      end

      def self.absolute(path, base)
        path = Tools::ToolPath.normalize(path)
        path.empty? ? nil : File.expand_path(path, base)
      end

      # The file memory_write would write; nil when the call is invalid.
      def self.memory_path(call, model_key)
        entry = call[:path].to_s.strip
        return nil if entry.empty? || call[:scope].to_s.strip.empty?

        dir = Tools::MemoryRead.memories_dir(Tools::MemoryRead.normalize_scope(call[:scope]))
        overlay = call[:current_model_only].to_s.strip.downcase == "true" && model_key
        File.expand_path(overlay ? "#{entry}.#{model_key}.md" : "#{entry}.md", dir)
      rescue StandardError
        nil
      end

      def initialize(tool:, command:, paths:, cwd:, repo_root:)
        @tool = tool
        @command = command
        @paths = paths
        @cwd = cwd
        @repo_root = repo_root
      end

      def shell? = SHELL_TOOLS.include?(@tool)

      # Whether any path is outside the repo root (the cwd outside a repo).
      def outside_repo?
        root = @repo_root || @cwd
        @paths.any? { |p| p != root && !p.start_with?(File.join(root, "")) }
      end

      # The hook event's targets: hash.
      def to_h
        { command: @command, paths: @paths, cwd: @cwd, repo_root: @repo_root, outside_repo: outside_repo? }
      end
    end
  end
end
