# frozen_string_literal: true

require_relative "../tools/tool_path"
require_relative "../tools/memory"
require_relative "../log"
require_relative "model_size"

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

      # @return [String, nil] the effective model: its bare name (no host
      #   prefix) and its key (ModelOverlay.key_for), for a rule's models:
      attr_reader :model_name, :model_key

      # @return [Hash, nil] a plugin tool's arguments (call[:args]), for an
      #   approval of a call whose targets name no command or path; nil for
      #   chi's own tools
      attr_reader :args

      # @param call [Hash] the parsed tool call
      # @param context [Context]
      # @param model_key [String, nil] for a memory_write model overlay, and
      #   a rule's models:
      # @param model_name [String, nil] the bare model name, for a rule's models:
      # @param registry [Tools::Registry, nil] the session's tools: a plugin
      #   tool's entry says what it acts on (its targets:)
      def self.for(call, context, model_key: nil, model_name: nil, registry: nil)
        tool = call[:name].to_s
        base = context.cwd
        command = nil
        paths = []
        cwd = base
        args = nil
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
        else
          given = plugin_targets(call, registry)
          command = given[:command]
          given_cwd = given[:cwd].to_s.strip
          cwd = File.expand_path(given_cwd, base) unless given_cwd.empty?
          paths.concat(given[:paths].map { |path| absolute(path, cwd) })
          entry = registry && registry[tool]
          args = call[:args] if entry && !entry.core? && call[:args].is_a?(Hash)
        end
        new(tool: tool, command: command, paths: paths.compact, cwd: cwd, repo_root: context.repo_root(cwd), args: args,
            model_name: model_name, model_key: model_key)
      end

      # What a plugin tool's targets: callable says the call acts on:
      # {command:, paths:, cwd:}, each optional; a callable that raises or
      # gives something else counts as nothing (and is logged).
      def self.plugin_targets(call, registry)
        entry = registry && registry[call[:name].to_s]
        none = { command: nil, paths: [], cwd: nil }
        return none unless entry && !entry.core? && entry.targets

        given = entry.targets.call(call)
        return none unless given.is_a?(Hash)

        given = given.transform_keys(&:to_sym)
        command = given[:command].to_s
        { command: command.empty? ? nil : command, paths: Array(given[:paths]).map(&:to_s), cwd: given[:cwd] }
      rescue StandardError => e
        Log.warn(:plugins, "plugin_targets_failed", tool: call[:name].to_s, error: e.class.name,
                                                    msg: "#{call[:name]} targets failed: #{e.message}")
        none
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

      def initialize(tool:, command:, paths:, cwd:, repo_root:, args: nil, model_name: nil, model_key: nil)
        @args = args
        @model_name = model_name
        @model_key = model_key
        @tool = tool
        @command = command
        @paths = paths
        @cwd = cwd
        @repo_root = repo_root
      end

      def shell? = SHELL_TOOLS.include?(@tool)

      # Whether the effective model is a small one (guardrails.small_models,
      # read when first asked: once per call's targets).
      def small_model?
        return @small_model if defined?(@small_model)

        @small_model = ModelSize.small?(@model_name, @model_key)
      end

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
