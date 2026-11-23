# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require_relative "../pages"
require_relative "../child_env"
require_relative "../process_group"

module Samagotchi
  module Pages
    # One run of a page: the one launch path, for `chi page run` and (Build 2)
    # chi web's Refresh alike. It takes the page's lock, starts the runner
    # (pages/runner.rb) in a process group of its own, in the pages folder,
    # with this process's environment as a worker gets it (the Bundler changes
    # undone, the spawner's keys unset, the XDG dirs absolute), reads its
    # stdout and stderr through bounded readers, and cuts it at +timeout+.
    # The runner writes the output file; a cut, or a runner that ended without
    # writing one, is recorded here (Store.record_failure). Whatever the
    # script left running in its group is killed after any exit.
    # ContextFetch#run_command is the model.
    module Launch
      # This chi's lib: the runner is started from the same code (a checkout
      # or an installed gem alike).
      LIB_DIR = File.expand_path("../..", __dir__)
      BOOT = 'require "samagotchi/pages/runner"; exit Samagotchi::Pages::Runner.run(ARGV)'
      PIPE_CAP = 64 * 1024
      # How long the group gets after TERM before KILL, and the readers
      # after the exit.
      GRACE_SECONDS = 1.0
      POLL_SECONDS = 0.05

      # +page+ the stored page after the run; +stdout+ / +stderr+ the
      # script's own words (their last 64 KB); +seconds+ the run's wall time.
      Result = Data.define(:ok, :page, :stdout, :stderr, :seconds) do
        def ok? = ok
      end

      module_function

      # @raise [BadName] [Missing] [Busy]
      # @return [Result]
      def run(name, timeout: TIMEOUT_SECONDS)
        Pages.check_name!(name)
        raise Missing, name unless File.file?(Pages.script_path(name))

        Store.locked(name) do
          # Again under the lock: a `chi page rm` between the check above and
          # the lock removed the page, so this run writes nothing (not even
          # the lock file it just made).
          unless File.file?(Pages.script_path(name))
            FileUtils.rm_f(Store.lock_path(name))
            raise Missing, name
          end

          launch(name, timeout)
        end
      end

      def command(name) = [RbConfig.ruby, "-I", LIB_DIR, "-e", BOOT, name]

      # The changes to this process's env a run gets, as a worker's
      # (SessionManager::WorkerCommand#spawn_options): an installed gem's
      # Bundler changes mapped back, the spawner's keys unset, the XDG dirs
      # absolute. PWD is set to the pages folder too: spawn's chdir doesn't
      # change it, and a script reading ENV["PWD"] would otherwise see the
      # caller's folder, so the terminal and chi web would differ.
      def env
        ChildEnv.unbundled.merge(ChildEnv.unset).merge(Paths.absolute_xdg).merge("PWD" => Pages.scripts_dir)
      end

      def launch(name, timeout)
        before = Store.file_id(name)
        started = monotonic
        out_r, out_w = IO.pipe
        err_r, err_w = IO.pipe
        pid = ProcessGroup.spawn(env, *command(name), chdir: Pages.scripts_dir, in: File::NULL, out: out_w, err: err_w)
        out_w.close
        err_w.close
        readers = [out_r, err_r].map { |io| ProcessGroup::PipeReader.new(io, cap: PIPE_CAP, keep: :tail) }

        status, cut = wait(pid, timeout)
        reaped = true
        # A script's background child would hold the pipes open.
        ProcessGroup.signal(pid, "KILL")
        readers.each { |reader| reader.wait(GRACE_SECONDS) || reader.kill }
        stdout, stderr = readers.map { |reader| reader.text(Encoding::UTF_8).scrub }
        ok = record(name, status, cut, timeout, before, stderr)
        Result.new(ok: ok, page: Store.read(name), stdout: stdout, stderr: stderr, seconds: monotonic - started)
      ensure
        # Cut short (Ctrl-C, an exception): the group doesn't get the
        # terminal's SIGINT (pgroup), so stop and reap it here.
        abandon(pid, readers) if pid && !reaped
        [out_r, out_w, err_r, err_w].each { |io| io.close if io && !io.closed? }
      end

      # @return [Boolean] whether the run was good. A cut or a runner that
      # ended without its result is recorded here; the runner recorded the rest.
      def record(name, status, cut, timeout, before, stderr)
        sha = Store.script_sha(name)
        if cut
          Store.record_failure(name, message: "the script was stopped after #{seconds(timeout)} s", line: nil, script_sha: sha)
          return false
        end

        written = Store.file_id(name)
        if written.nil? || written == before || ![0, 1].include?(status&.exitstatus)
          # Not a backtrace frame: a Ruby crash ends stderr with "from …" lines.
          tail = stderr.lines.map(&:strip).reject { |line| line.empty? || line.start_with?("from ") }.last
          Store.record_failure(name, message: ["the runner ended without a result", tail].compact.join(": "), line: nil,
                                     script_sha: sha)
          return false
        end

        status.exitstatus.zero? && Store.read(name).state == :ok
      end

      # @return [Array(Process::Status|nil, Boolean)] the status, and whether
      #   it was cut at the timeout
      def wait(pid, timeout)
        deadline = monotonic + timeout
        loop do
          _, status = Process.wait2(pid, Process::WNOHANG)
          return [status, false] if status
          return [stop_group(pid), true] if monotonic > deadline

          sleep(POLL_SECONDS)
        end
      end

      # TERM the group, a grace, then KILL; the reap ends the wait.
      # @return [Process::Status, nil]
      def stop_group(pid)
        status = nil
        reaped = -> { status = Process.wait2(pid, Process::WNOHANG)&.last }
        return status if ProcessGroup.stop(pid, grace: GRACE_SECONDS, poll: POLL_SECONDS, stopped: reaped)

        status || Process.wait2(pid).last
      rescue Errno::ECHILD
        status
      end

      def abandon(pid, readers)
        stop_group(pid)
        ProcessGroup.signal(pid, "KILL")
        Array(readers).each(&:kill)
      end

      def seconds(value) = format("%g", value)

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
