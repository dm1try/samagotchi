# frozen_string_literal: true

require "fileutils"
require_relative "../memory_bundle/shas"
require_relative "../version"
require_relative "../cli/flags"

module Samagotchi
  class BundleCommand
    # `chi bundle new NAME [--dir DIR]`: a bundle to start from, in DIR/NAME:
    # a manifest (block-form plugin: entry, its sha filled, requires_chi at
    # this chi), a plugin with one command and one after_tool_call hook, a
    # Minitest test on the kit that passes as written, and a README. The
    # test is the pattern to copy (docs/bundle-authoring.md).
    class Scaffold
      HELP = <<~TEXT
        Usage: chi bundle new NAME [--dir DIR]

          Start a bundle in DIR/NAME (default ./NAME; refused when it exists): manifest.yml (shas filled,
          requires_chi this chi), plugin.rb (a /NAME command and an after_tool_call hook), test/NAME_test.rb
          (passes as written) and README.md. Then: chi bundle test, chi bundle check, chi bundle install.
      TEXT
      FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A--/) do |f|
        f.value "--dir"
      end

      # A name that is also a slash command (Plugin::Api::COMMAND_NAME).
      NAME = /\A[a-z][a-z0-9_-]{0,31}\z/

      # @return [String] the bundle's folder
      attr_reader :dir

      def initialize(name, parent: ".")
        @name = name
        @dir = File.expand_path(name, parent)
      end

      # Write the files; ArgumentError for a bad name or a folder that's there.
      # @return [Array<String>] the files written, relative to #dir
      def write
        raise ArgumentError, "#{@name.inspect} isn't a bundle name: a-z first, then a-z, 0-9, - or _ (32 at most)" unless @name.match?(NAME)
        raise ArgumentError, "#{@dir} exists already" if File.exist?(@dir)

        files.each do |rel, text|
          FileUtils.mkdir_p(File.dirname(File.join(@dir, rel)))
          File.write(File.join(@dir, rel), text)
        end
        File.write(File.join(@dir, "manifest.yml"), MemoryBundle::Shas.refresh(@dir).first)
        files.keys
      end

      private

      def test_file = "test/#{@name.tr("-", "_")}_test.rb"
      def test_class = "#{@name.split(/[-_]/).map(&:capitalize).join}Test"

      def files
        { "manifest.yml" => manifest, "plugin.rb" => plugin, test_file => test, "README.md" => readme }
      end

      def manifest
        <<~YAML
          name: #{@name}
          version: 0.1.0
          scope: system
          description: "What #{@name} adds to chi, in one line"
          requires_chi: ">= #{VERSION}"
          plugin:
            file: plugin.rb
            sha256: sha256:
        YAML
      end

      def plugin
        <<~RUBY
          # frozen_string_literal: true

          # #{@name}: one slash command and one hook (docs/bundle-authoring.md in chi's source dir).
          class Plugin
            # settings: config.yml `bundles: #{@name}:` (string keys), read once when the plugin loads.
            def initialize(settings)
              @greeting = settings.fetch("greeting", "hello")
            end

            def register(chi)
              # /#{@name} [WHO]: the block gets the text after the name and returns what to show.
              chi.command("/#{@name}", "say hello") do |args, _ctx|
                "\#{@greeting}, \#{args.empty? ? "there" : args}"
              end

              # After each tool call: an execute that exited non-zero gets one notice. Match on event[:result]
              # (the tool's own text, ending in "exit: N"), not event[:output] (what the model reads, maybe cut).
              chi.on(:after_tool_call) do |event, ctx|
                next unless event[:tool] == "execute"

                code = event[:result].to_s[/^exit: (\\d+)/, 1].to_i
                ctx.notify("the command exited \#{code}", level: :warn) unless code.zero?
              end
            end
          end
        RUBY
      end

      def test
        <<~RUBY
          # frozen_string_literal: true

          require "minitest/autorun"
          require "samagotchi/testing/minitest"

          # `chi bundle test` runs this with chi's own Ruby and lib. Each test gets a sandbox (temp HOME, config,
          # state); load_bundle loads the bundle's source through chi's loaders, and the recorders show what it did.
          class #{test_class} < Samagotchi::Testing::Case
            BUNDLE = File.expand_path("..", __dir__)

            def test_the_command_greets
              assert_equal "hello, chi", load_bundle(BUNDLE).command("/#{@name} chi")
              assert_equal "hi, there", load_bundle(BUNDLE, settings: { "greeting" => "hi" }).command("/#{@name}")
            end

            def test_a_failed_execute_gets_a_notice
              bundle = load_bundle(BUNDLE)
              # An execute's after_tool_call as chi fires it (docs/hooks.md, Hook Events).
              bundle.fire(:after_tool_call, tool: "execute", status: "error", iteration: 1, elapsed_ms: 12,
                                            call: { name: "execute", content: "false" },
                                            result: "exit: 1 (no output)", output: "[execute]\\nexit: 1 (no output)")
              bundle.fire(:after_tool_call, tool: "execute", status: "ok", iteration: 2, elapsed_ms: 9,
                                            call: { name: "execute", content: "echo hi" },
                                            result: "stdout:\\nhi\\n\\nexit: 0", output: "[execute]\\nstdout:\\nhi\\n\\nexit: 0")

              assert_equal [["the command exited 1", :warn]], bundle.notices.map { |n| [n.text, n.level] }
            end
          end
        RUBY
      end

      def readme
        <<~MD
          # #{@name}

          A chi bundle: `/#{@name}`, and a notice when a command fails.
          Check it with `chi bundle check`, test it with `chi bundle test`, install it with `chi bundle install .`
        MD
      end
    end
  end
end
