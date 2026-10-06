# frozen_string_literal: true

require_relative "context_sources"
require_relative "context_providers"
require_relative "log"

module Samagotchi
  # Runs an attached context source's command once and records the result
  # in its snapshot (ContextSources): the worker's ContextPoller and
  # `chi context refresh` both come here.
  #
  # The command runs with `sh -c` in its own process group (a timeout, the
  # output cap or the caller's cancel kills the group: no orphans), in
  # +cwd+, with stdin closed, SAMAGOTCHI_CONTEXT_NAME and (once there is
  # one) SAMAGOTCHI_CONTEXT_PREVIOUS, the last snapshot's path. stdout is
  # the text (ContextSources.parse_output); stderr goes to the debug log,
  # its last line into the error. A non-blocking flock on <name>.lock keeps
  # two workers (or a worker and the CLI) from running one source at once.
  module ContextFetch
    TIMEOUT_SECONDS = 60
    STDERR_TAIL_BYTES = 4096
    READ_CHUNK = 64 * 1024
    # How long a group gets after TERM before KILL.
    KILL_GRACE_SECONDS = 1.0
    OVER_CAP = "it printed more than 1 MiB"

    # +status+: :new (a new revision), :same (the same text), :error (the
    # fetch failed: +error+), :busy (another process holds the lock),
    # :fresh (tried within +fresh_within+, by someone else meanwhile),
    # :cancelled (the caller stopped it: nothing recorded, since a worker
    # leaving isn't the source failing).
    Outcome = Data.define(:status, :snapshot, :error)
    # What the command did: +output+ its stdout, +error+ nil or why it
    # failed, +cancelled+ the caller stopped it.
    Run = Data.define(:output, :error, :stderr, :cancelled)

    module_function

    # @param attached [ContextSources::Attached] a command source
    # @param fresh_within [Numeric, nil] skip it when it was tried this
    #   many seconds ago (checked under the lock)
    # @param cancelled [#call] true: kill the command (the worker stops)
    # @return [Outcome]
    def fetch(attached, cwd:, fresh_within: nil, timeout: TIMEOUT_SECONDS, cancelled: -> { false })
      location = attached.location
      name = attached.name
      File.open(location.lock_path(name), File::RDWR | File::CREAT, 0o644) do |lock|
        return Outcome.new(status: :busy, snapshot: nil, error: nil) unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        before = location.snapshot(name)
        age = before.age
        return Outcome.new(status: :fresh, snapshot: before, error: nil) if fresh_within && age && age < fresh_within

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        run = begin
          run_command(ContextProviders.command_for(attached.source), cwd: cwd, env: env_for(location, name),
                                                                     timeout: timeout, cancelled: cancelled)
        rescue ContextProviders::Invalid => e
          Run.new(output: nil, error: e.message, stderr: "", cancelled: false)
        end
        outcome = if run.cancelled
                    Outcome.new(status: :cancelled, snapshot: before, error: nil)
                  else
                    record(location, name, run, before)
                  end
        Log.info(:context, "fetched", name: name, scope: location.scope, status: outcome.status,
                                      ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
                                      error: outcome.error)
        outcome
      end
    end

    def record(location, name, run, before)
      if run.error
        snapshot = location.record_error(name, run.error)
        return Outcome.new(status: :error, snapshot: snapshot, error: snapshot.error)
      end

      begin
        fetched = ContextSources.parse_output(run.output)
      rescue ContextSources::Invalid => e
        snapshot = location.record_error(name, e.message)
        return Outcome.new(status: :error, snapshot: snapshot, error: snapshot.error)
      end
      snapshot = location.record_text(name, fetched)
      Outcome.new(status: snapshot.revision == before.revision ? :same : :new, snapshot: snapshot, error: nil)
    end

    def env_for(location, name)
      previous = location.snapshot_path(name)
      { "SAMAGOTCHI_CONTEXT_NAME" => name,
        "SAMAGOTCHI_CONTEXT_PREVIOUS" => File.exist?(previous) ? previous : nil }
    end

    # @return [Run]
    def run_command(cmd, cwd:, env:, timeout:, cancelled:)
      return Run.new(output: nil, error: "its folder #{cwd} is gone", stderr: "", cancelled: false) unless cwd && Dir.exist?(cwd)

      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = Process.spawn(env, "sh", "-c", cmd, chdir: cwd, pgroup: true, in: File::NULL, out: out_w, err: err_w)
      out_w.close
      err_w.close
      output = +""
      over = false
      out_reader = Thread.new do
        loop do
          chunk = out_r.readpartial(READ_CHUNK)
          if output.bytesize + chunk.bytesize > ContextSources::TEXT_MAX_BYTES
            over = true
            break
          end
          output << chunk
        end
      rescue IOError # EOFError too
        nil
      end
      stderr = +""
      err_reader = Thread.new do
        loop do
          stderr << err_r.readpartial(READ_CHUNK)
          stderr = stderr.byteslice(-STDERR_TAIL_BYTES, STDERR_TAIL_BYTES) if stderr.bytesize > STDERR_TAIL_BYTES
        end
      rescue IOError # EOFError too
        nil
      end

      error, status = wait(pid, timeout: timeout, over: -> { over }, cancelled: cancelled)
      reaped = true
      # Whatever the command left running in its group goes with it.
      signal_group(pid, "KILL")
      [out_reader, err_reader].each { |thread| thread.join(KILL_GRACE_SECONDS) || thread.kill }
      stderr_text = stderr.dup.force_encoding(Encoding::UTF_8).scrub
      Log.debug(:context, "stderr", text: stderr_text[-1000..] || stderr_text) unless stderr_text.strip.empty?
      return Run.new(output: nil, error: nil, stderr: stderr_text, cancelled: true) if error == :cancelled

      # Checked again once the reader is done: a command that exits before
      # wait's next tick never gets an over from it.
      error = OVER_CAP if over
      error ||= exit_error(status, stderr_text)
      Run.new(output: output, error: error, stderr: stderr_text, cancelled: false)
    rescue SystemCallError => e
      Run.new(output: nil, error: "couldn't run it: #{e.message}", stderr: "", cancelled: false)
    ensure
      # Cut short (Ctrl-C in chi context refresh, an exception, a killed
      # poller thread): the group doesn't get the terminal's SIGINT
      # (pgroup), so stop and reap it here.
      abandon(pid, [out_reader, err_reader]) if pid && !reaped
      [out_r, out_w, err_r, err_w].each { |io| io&.close unless io&.closed? }
    end

    # @return [Array(String|Symbol|nil, Process::Status|nil)] why it was
    #   stopped (:cancelled for the caller), and its status
    def wait(pid, timeout:, over:, cancelled:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)
        return [nil, status] if status

        reason = if over.call then OVER_CAP
                 elsif cancelled.call then :cancelled
                 elsif Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline then "timed out after #{timeout.round} s"
                 end
        return [reason, stop_group(pid)] if reason

        sleep(0.05)
      end
    end

    def abandon(pid, readers)
      stop_group(pid)
      readers.each { |thread| thread&.kill }
    rescue StandardError => e
      Log.warn(:context, "stop_failed", pid: pid, error: e.class.name)
    end

    # TERM, then KILL after a grace; @return [Process::Status, nil]
    def stop_group(pid)
      signal_group(pid, "TERM")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + KILL_GRACE_SECONDS
      until Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        _, status = Process.wait2(pid, Process::WNOHANG)
        return status if status

        sleep(0.05)
      end
      signal_group(pid, "KILL")
      Process.wait2(pid).last
    rescue Errno::ECHILD
      nil
    end

    def signal_group(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def exit_error(status, stderr)
      return nil if status.nil? || status.success?

      last = stderr.lines.map(&:strip).reject(&:empty?).last
      code = status.exitstatus ? "exit #{status.exitstatus}" : "killed by signal #{status.termsig}"
      last ? "#{code}: #{last}" : code
    end
  end
end
