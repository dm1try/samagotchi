# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tempfile"
require_relative "bounded_capture"
require_relative "waiting"

# Running bin/chi in a child process. Included in every example group by
# spec_helper; a file whose calls all share arguments wraps it in its own
# run_chi and calls super.
#
#   out, err, status = run_chi("sessions", "list", env: { "XDG_STATE_HOME" => dir })
#
# fork_chi runs the same bin/chi in a fork of this process instead: no Ruby
# boot and no requires the suite has already done (~2 s a run under load).
# A fork inherits this process's loaded code, so it can't catch a require
# bin/chi (or a subcommand's file) lacks: a file keeps one run_chi per
# mechanism and forks the rest. It inherits this process's state too: the
# example's rspec stubs and the suite's global ones (BundleNeeds' rg, Reline,
# the NullKeychain, the cleared Samagotchi::Bundles constants, the warning
# categories) and the flags of what warns once per process (PromptCache,
# ModelNotes, Approvals). Anything that asserts on those takes a real
# run_chi.
module ChiCli
  CHI = File.expand_path("../../bin/chi", __dir__)

  # A chi of its own under +dir+: config, state and HOME there, and none of
  # the model settings the suite's ENV may carry.
  def isolated_chi_env(dir, **extra)
    { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
      "SAMAGOTCHI_DEFAULT_MODEL" => nil, "SAMAGOTCHI_MODEL_PROFILE" => nil }.merge(extra)
  end

  # Run chi with empty stdin. With +timeout+ the whole process group is
  # killed past it (BoundedCapture), for a run that could hang.
  # @return [Array(String, String, Process::Status)]
  def run_chi(*, env: {}, chdir: nil, timeout: nil)
    return BoundedCapture.capture3(env, RbConfig.ruby, CHI, *, stdin_data: "", timeout: timeout, chdir: chdir) if timeout

    Open3.capture3(env, RbConfig.ruby, CHI, *, stdin_data: "", **(chdir ? { chdir: chdir } : {}))
  end

  # run_chi with +spawn+, else fork_chi: a file's one real run among forks.
  def run_or_fork_chi(*, spawn:, **) = spawn ? run_chi(*, **) : fork_chi(*, **)

  # bin/chi with +args+ in a fork: ARGV, +env+ (nil unsets) and +chdir+ set
  # there, stdin empty, stdout and stderr captured (the process's own fds,
  # whatever $stdout an example swapped in), every exit (and an
  # uncaught error, as ruby prints it) a real exit status. The fork leaves
  # with exit!, so none of the suite's at_exit hooks run in it; past
  # +timeout+ its process group is killed and the example fails.
  # @return [Array(String, String, Process::Status)]
  def fork_chi(*args, env: {}, chdir: nil, timeout: 60)
    ChiCli.preload
    out = Tempfile.new("fork-chi-out")
    err = Tempfile.new("fork-chi-err")
    pid = fork { ChiCli.run_forked(args, env, chdir, out.path, err.path) }
    status = ChiCli.reap(pid, timeout, args)
    [File.read(out.path), File.read(err.path), status]
  ensure
    [out, err].each { |file| file&.close! }
  end

  # What bin/chi requires on every run, loaded once in the parent.
  def self.preload
    @preload ||= begin
      require "optparse"
      require "samagotchi"
      true
    end
  end

  # The fork's body: never returns.
  def self.run_forked(args, env, chdir, out_path, err_path)
    status = 1
    begin
      Process.setpgrp
      STDIN.reopen(File::NULL)
      STDOUT.reopen(out_path, "w")
      STDERR.reopen(err_path, "w")
      $stdin = STDIN
      $stdout = STDOUT
      $stderr = STDERR
      $VERBOSE = false # a real ruby's default; the suite runs with warnings on
      env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      Dir.chdir(chdir) if chdir
      WebMock.disable! if defined?(WebMock) # a real chi's requests are real
      ARGV.replace(args)
      load CHI
      status = 0
    rescue SystemExit => e
      status = e.status
    rescue Exception => e # rubocop:disable Lint/RescueException -- ruby's own top level reports any error
      $stderr.puts(e.full_message(highlight: false))
    ensure
      $stdout.flush
      $stderr.flush
      exit!(status)
    end
  end

  # Wait for the fork; kill its group past +timeout+, or when the wait
  # itself is cut short (an interrupt, the example's time limit), so no
  # fork outlives its example.
  def self.reap(pid, timeout, args)
    status = nil
    done = SpecWaiting.wait_until(timeout: timeout, interval: 0.005) { status = Process.wait2(pid, Process::WNOHANG)&.last }
    return status if done

    raise "bin/chi #{args.join(" ")} (forked) did not finish in #{timeout} s"
  ensure
    kill_fork(pid) unless status
  end

  def self.kill_fork(pid)
    [-pid, pid].each do |target|
      Process.kill("KILL", target)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end
end
