# frozen_string_literal: true

require_relative "../pages"

module Samagotchi
  module Pages
    # The page runner: the process Launch starts for one run of one page,
    #   ruby -I <lib> -e 'require "samagotchi/pages/runner"; exit Samagotchi::Pages::Runner.run(ARGV)' NAME [TIMEOUT DEADLINE]
    # with the page's lock on fd 3. It holds that lock while it lives and,
    # given a DEADLINE (seconds from its start), stops itself and its group
    # there, recording the cut: a launcher killed mid-run (chi web) leaves at
    # most one bounded run, and the page "already running" until it ends.
    # Requiring this file runs nothing. It loads Pages only (no engine, no
    # config, no web, no plugins, no ProcessGroup), so a run is as light as a
    # Ruby script, and a page's surroundings are the same from the terminal
    # and from chi web.
    #
    # The script is loaded with a fresh module as its wrap (Kernel#load), which
    # gives it `page` and `runtime` and keeps its own methods off Object. What the run built,
    # or what it raised, goes to the output file (Store), never to stdout: a
    # `puts` in a script is the script's own. A TERM (Launch's cut) is not
    # rescued: the launcher records the cut itself.
    module Runner
      # The script's `page "Title" do |ui| … end`, once per run, and its
      # `runtime` (Pages::Runtime, made on first use: a page that never asks
      # loads none of it).
      class Collector
        attr_reader :builder

        def dsl
          collector = self
          Module.new do
            define_method(:page) do |title, &block|
              collector.page(title, &block)
            end
            define_method(:runtime) { collector.runtime }
          end
        end

        def runtime = @runtime ||= Runtime.new

        def page(title)
          raise Refused, "a page script calls page once" if @builder

          @builder = Builder.new(title)
          yield @builder if block_given?
          nil
        end
      end

      # The fd Launch hands the page's lock on (Launch::LOCK_FD).
      LOCK_FD = 3

      module_function

      # @param argv [Array<String>] [NAME] or [NAME, TIMEOUT, DEADLINE]
      # @return [Integer] 0 the page ran, 1 the script failed (recorded), 2
      #   no such page (nothing recorded: Launch checks this first)
      def run(argv)
        hold_lock
        name, timeout, deadline = argv
        return 2 unless Pages.valid_name?(name) && File.file?(Pages.script_path(name))

        # The deadline thread and the result's write take this in turn, and
        # the write sets done under it: a run recorded before the deadline
        # fires (an at_exit still going, the exit itself) is never
        # overwritten by the cut.
        recording = Mutex.new
        done = [false]
        arm_deadline(name, timeout, Float(deadline), recording, done) if deadline
        path = Pages.script_path(name)
        sha = Digest::SHA256.file(path).hexdigest
        collector = Collector.new
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          load(path, collector.dsl)
          raise Refused, "the script never called page" unless collector.builder

          data = collector.builder.data
          ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
          recording.synchronize do
            Store.record_run(name, title: data["title"], blocks: data["blocks"], duration_ms: ms, script_sha: sha)
            done[0] = true
          end
          0
        # SystemStackError (endless recursion) and NoMemoryError are no
        # StandardError, but a script's own bug all the same.
        rescue StandardError, ScriptError, SystemExit, SystemStackError, NoMemoryError => e
          recording.synchronize do
            Store.record_failure(name, message: message(e, path), line: line(e, path), script_sha: sha)
            done[0] = true
          end
          1
        end
      end

      # The first act: the inherited lock fd is close-on-exec here, so the
      # runner holds the lock alone. A child the script execs, even one that
      # leaves the group (and so outlives the run), never inherits it: it
      # would keep the page "already running" for as long as it lives. A
      # runner started by hand has no lock there: fd 3 is closed (EBADF) or,
      # as Ruby keeps it for itself when nothing is inherited there, refused
      # (ArgumentError, "RubyVM reserves it").
      def hold_lock
        IO.for_fd(LOCK_FD, autoclose: false).close_on_exec = true
      rescue Errno::EBADF, ArgumentError
        nil
      end

      # At +deadline+ seconds from now the cut is recorded (a dead launcher
      # can't), unless the run's own result is already written (+done+), and
      # the runner's whole group is KILLed either way (it leads its group).
      # A Ruby thread: it can't fire while a C extension holds the GVL
      # (docs/internals/pages.md). Plain Process calls, no ProcessGroup, to
      # stay light.
      def arm_deadline(name, timeout, deadline, recording, done)
        Thread.new do
          sleep(deadline)
          recording.lock
          begin
            unless done[0]
              Store.record_failure(name, message: "the script was stopped after #{timeout} s", line: nil,
                                         script_sha: Store.script_sha(name))
            end
          # Not an ensure: a normal exit kills this thread, and its ensure would KILL the group.
          rescue StandardError # degrade-ok: the KILL matters more than the record (a dead launcher records nothing)
            nil
          end
          Process.kill("KILL", -Process.pid)
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
