# frozen_string_literal: true

require "rbconfig"

module Samagotchi
  class BundleCommand
    # `chi bundle test [PATH] [-- ARGS]`: a bundle's tests on the Ruby and
    # the lib chi runs on (RbConfig.ruby, -I chi's lib), which an external
    # bundle can't easily find itself (mise, rbenv, gem paths). test/**/
    # *_test.rb runs on Minitest with the kit's Case; a spec/ with no test/
    # on RSpec with the kit's helpers, as `rake bundles:specs` runs the
    # shipped ones. Outside any Bundler env (Bundler.with_unbundled_env, as
    # InstalledGem.unbundled_env_changes), where chi's own gem dependency minitest loads.
    # When the framework loads only inside the Bundler env chi itself runs in
    # (a checkout or a vendored install: its gems in vendor/bundle), there.
    # The tests' exit status is #run's.
    class TestRun
      LIB_DIR = File.expand_path("../..", __dir__)

      def initialize(dir, args: [], stdout: $stdout, stderr: $stderr)
        @dir = File.expand_path(dir)
        @args = args
        @stdout = stdout
        @stderr = stderr
      end

      # @return [Integer] exit status
      def run
        tests = Dir.glob(File.join(@dir, "test", "**", "*_test.rb")).sort
        return minitest(tests) if tests.any?
        return rspec if File.directory?(File.join(@dir, "spec"))

        @stderr.puts "chi bundle test: no test/*_test.rb or spec/ in #{@dir} (chi bundle new NAME writes a test to copy)"
        CLI::Exit::FAILED
      end

      private

      def minitest(tests)
        return missing("minitest", "it ships with chi: reinstall chi (gem install samagotchi)") unless loads?("minitest")

        requires = tests.map { |file| "require #{file.inspect}" }.join("; ")
        say("#{tests.size} test file#{"s" unless tests.size == 1}")
        spawn(RbConfig.ruby, "-I", LIB_DIR, "-r", "minitest/autorun", "-r", "samagotchi/testing/minitest", "-e", requires,
              "--", *@args)
      end

      def rspec
        return missing("rspec", "gem install rspec") unless loads?("rspec/core")

        say("spec/ on RSpec")
        spawn(RbConfig.ruby, "-I", LIB_DIR, "-r", "rspec/core", "-e", "exit RSpec::Core::Runner.run(ARGV)", "--",
              "--options", File::NULL, "-r", "samagotchi/testing/rspec", "spec", *@args)
      end

      def say(what) = @stdout.puts("chi bundle test: #{what} on #{RbConfig.ruby} (chi's lib #{LIB_DIR})")

      def missing(lib, hint)
        @stderr.puts "chi bundle test: #{lib} doesn't load on chi's Ruby (#{RbConfig.ruby}); #{hint}"
        CLI::Exit::USAGE
      end

      # Whether +lib+ loads unbundled, else in chi's own Bundler env (then
      # #spawn stays in it).
      def loads?(lib)
        check = -> { system(RbConfig.ruby, "-e", "require #{lib.inspect}", out: File::NULL, err: File::NULL) }
        @bundled = false
        return true if unbundled(&check)

        @bundled = bundler?
        @bundled && check.call
      end

      def spawn(*command)
        @stdout.flush
        run = -> { system(*command, chdir: @dir) }
        @bundled ? run.call : unbundled(&run)
        $?.exitstatus || CLI::Exit::FAILED
      end

      def unbundled(&)
        bundler? ? ::Bundler.with_unbundled_env(&) : yield
      end

      # Bundler may be defined without its runtime (RubyGems' own stub).
      def bundler? = defined?(::Bundler) && ::Bundler.respond_to?(:with_unbundled_env)
    end
  end
end
