# frozen_string_literal: true

require_relative "../pages"

module Samagotchi
  module Pages
    # The page runner: the process Launch starts for one run of one page,
    #   ruby -I <lib> -e 'require "samagotchi/pages/runner"; exit Samagotchi::Pages::Runner.run(ARGV)' NAME
    # Requiring this file runs nothing. It loads Pages only (no engine, no
    # config, no web, no plugins, no ProcessGroup), so a run is as light as a
    # Ruby script, and a page's surroundings are the same from the terminal
    # and from chi web.
    #
    # The script is loaded with a fresh module as its wrap (Kernel#load), which
    # gives it `page` and keeps its own methods off Object. What the run built,
    # or what it raised, goes to the output file (Store), never to stdout: a
    # `puts` in a script is the script's own. A TERM (Launch's cut) is not
    # rescued: the launcher records the cut itself.
    module Runner
      # The script's `page "Title" do |ui| … end`, once per run.
      class Collector
        attr_reader :builder

        def dsl
          collector = self
          Module.new do
            define_method(:page) do |title, &block|
              collector.page(title, &block)
            end
          end
        end

        def page(title)
          raise Refused, "a page script calls page once" if @builder

          @builder = Builder.new(title)
          yield @builder if block_given?
          nil
        end
      end

      module_function

      # @param argv [Array<String>] [NAME]
      # @return [Integer] 0 the page ran, 1 the script failed (recorded), 2
      #   no such page (nothing recorded: Launch checks this first)
      def run(argv)
        name = argv.first
        return 2 unless Pages.valid_name?(name) && File.file?(Pages.script_path(name))

        path = Pages.script_path(name)
        sha = Digest::SHA256.file(path).hexdigest
        collector = Collector.new
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          load(path, collector.dsl)
          raise Refused, "the script never called page" unless collector.builder

          data = collector.builder.data
          ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
          Store.record_run(name, title: data["title"], blocks: data["blocks"], duration_ms: ms, script_sha: sha)
          0
        # SystemStackError (endless recursion) and NoMemoryError are no
        # StandardError, but a script's own bug all the same.
        rescue StandardError, ScriptError, SystemExit, SystemStackError, NoMemoryError => e
          Store.record_failure(name, message: message(e, path), line: line(e, path), script_sha: sha)
          1
        end
      end

      # The error as the page shows it: a syntax error without its leading
      # "path:line:" (its line is #line's), an exit as what it was.
      def message(error, path)
        case error
        when ScriptError then error.message.sub(/\A#{Regexp.escape(path)}:\d+:\s*/, "")
        when SystemExit
          words = error.message == "exit" ? nil : error.message
          words || "the script called exit #{error.status}"
        else error.message
        end
      end

      # The script's line: a syntax error's from its message's first line
      # (the rest differs between Rubies), anything else's from the first
      # backtrace entry inside the script file. nil when neither has one.
      def line(error, path)
        prefix = "#{path}:"
        if error.is_a?(ScriptError)
          found = error.message.lines.first.to_s[/\A#{Regexp.escape(prefix)}(\d+)/, 1]
          return found.to_i if found
        end
        entry = Array(error.backtrace).find { |frame| frame.start_with?(prefix) }
        entry && entry.delete_prefix(prefix)[/\A\d+/]&.to_i
      end
    end
  end
end
