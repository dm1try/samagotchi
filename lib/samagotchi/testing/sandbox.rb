# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"
require_relative "../log"
require_relative "../paths"
require_relative "../sandbox_layout"
require_relative "fake_executable"

module Samagotchi
  module Testing
    # The environment a bundle test runs in: temp config, state, data and cache
    # homes (config.yml, memories, ctx.data_dir, the debug log), HOME and the peer
    # CLIs' folders, git without the user's config, no Keychain, none of
    # the user's SAMAGOTCHI_* settings, a bin/ first on PATH for fake
    # commands. ENV is put back on #leave.
    #
    #   Samagotchi::Testing::Sandbox.with { |sandbox| sandbox.config("bundles" => {…}) … }
    #   sandbox = Samagotchi::Testing::Sandbox.enter   # … sandbox.leave
    class Sandbox
      # The environment switches a run of the test keeps (as the suite does).
      KEPT = %w[SAMAGOTCHI_LOG_STRICT].freeze

      class << self
        # The sandbox entered last and not left yet (Bundle.load uses it).
        # @return [Sandbox, nil]
        attr_accessor :current

        # @return [Sandbox] entered
        def enter = new.tap(&:enter)

        # Run the block in a new sandbox, left after it.
        # @yieldparam sandbox [Sandbox]
        def with
          sandbox = enter
          yield sandbox
        ensure
          sandbox&.leave
        end

        # +value+ with every Hash key a String, as config.yml and a
        # handler's args read (Bundle uses it too).
        # @api private
        def stringify(value)
          case value
          when Hash then value.to_h { |key, item| [key.to_s, stringify(item)] }
          when Array then value.map { |item| stringify(item) }
          else value
          end
        end
      end

      # @return [String] the temp folder holding everything
      attr_reader :root

      def initialize
        @root = nil
        @saved = nil
        @outer = nil
      end

      # Point ENV at fresh temp folders (and remember the previous ENV).
      # @return [self]
      def enter
        raise ArgumentError, "the sandbox was entered already" if @root

        layout = SandboxLayout.create("chi-bundle-test-", extra: %w[data cache home bin])
        @root = layout.root
        @saved = ENV.to_h
        @outer = Sandbox.current
        ENV.each_key.select { |key| key.start_with?("SAMAGOTCHI_") && !KEPT.include?(key) }.each { |key| ENV.delete(key) }
        File.write(File.join(@root, "gitconfig"), "")
        ENV.update(
          **layout.env,
          "HOME" => File.join(@root, "home"),
          "XDG_DATA_HOME" => File.join(@root, "data"),
          "XDG_CACHE_HOME" => File.join(@root, "cache"),
          "CLAUDE_CONFIG_DIR" => File.join(@root, "home", ".claude"),
          "CODEX_HOME" => File.join(@root, "home", ".codex"),
          "GIT_CONFIG_GLOBAL" => File.join(@root, "gitconfig"),
          "GIT_CONFIG_NOSYSTEM" => "1",
          "SAMAGOTCHI_KEYCHAIN" => "off",
          "SAMAGOTCHI_ENV" => "test",
          "PATH" => [bin_dir, ENV.fetch("PATH", nil)].compact.join(File::PATH_SEPARATOR)
        )
        # The log resolves its file from the (now temp) state home.
        Log.reset!
        Sandbox.current = self
        self
      end

      # Put ENV back as it was and remove the temp folders.
      def leave
        return unless @root

        ENV.replace(@saved)
        Log.reset!
        FileUtils.rm_rf(@root)
        Sandbox.current = @outer
        @root = @saved = @outer = nil
      end

      # Write config.yml (what Config.get reads): a Hash or YAML text.
      # @return [String] its path
      def config(data)
        SandboxLayout.new(@root).write_config(data.is_a?(String) ? data : stringify(data), config_home: Paths.config_home)
      end

      # @return [String] $XDG_STATE_HOME/samagotchi (ctx.data_dir's parent)
      def state_dir = Paths.state_dir

      # A memory scope's folder ("system", or "project" for the checkout
      # at +cwd+), as chi's memory tools and bundles find it; created.
      # @return [String]
      def memory_dir(scope = "system", cwd: Dir.pwd)
        require_relative "../memory_paths"
        MemoryPaths.scope_dir!(scope, cwd: cwd).tap { |dir| FileUtils.mkdir_p(dir) }
      end

      # Write a memory as memory_write does (the file and its index line,
      # with +description+), for the checkout at +cwd+ (the project scope's;
      # default the process's own); +source+ marks the line as a bundle's
      # ("· from <source>"), as an install writes it.
      # @return [String] the memory's path
      # @raise [ArgumentError] what memory_write refused
      def write_memory(name, content, scope: "system", description: nil, source: nil, cwd: nil)
        require_relative "../tools/memory"
        require_relative "../memory_bundle/index_updater"
        in_dir(cwd) do
          result = Tools::MemoryWrite.call(content, path: name, scope: scope, description: description)
          raise ArgumentError, result if result.start_with?("Error")

          MemoryBundle::IndexUpdater.update_index(scope, name, content.bytesize, description, source: source) if source
        end
        File.join(memory_dir(scope, cwd: cwd || Dir.pwd), "#{name}.md")
      end

      # @return [String] a temp folder for the session's cwd
      def work_dir = File.join(@root, "work")

      # @return [String] the folder first on PATH (#fake_executable's)
      def bin_dir = File.join(@root, "bin")

      # A command +name+ first on PATH that runs +body+ (sh) with its
      # arguments; again for the same name replaces the body.
      # @return [String] its path
      def fake_executable(name, body) = FakeExecutable.write(bin_dir, name, body)

      private

      # Run the block with +dir+ as the process's cwd (the memory tools
      # read the project from it); nil: as it is.
      def in_dir(dir, &)
        return yield if dir.nil? || File.expand_path(dir) == Dir.pwd

        Dir.chdir(dir, &)
      end

      def stringify(value) = Sandbox.stringify(value)
    end
  end
end
