# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "worker_links"

# What every spec/session_manager/*_spec.rb shares: a state dir (tmpdir)
# removed after each example, the manager a spawn goes through, and
# #spawn_owner's stand-in worker (killed after the example).
RSpec.shared_context "session manager files" do
  include WorkerLinks

  let(:tmpdir) { Dir.mktmpdir("session-manager-spec") }

  after do
    FileUtils.rm_rf(tmpdir)
    if @owner_pid
      begin
        Process.kill("KILL", @owner_pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.wait(@owner_pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end

  # A stand-in worker: another process holding the owner lock (needs the
  # example group's session and session_dir; spec/support/lock_holder.rb).
  def spawn_owner(ignore_term: false)
    @owner_pid = spawn_lock_holder(session_dir, ignore_term: ignore_term)
    expect(described_class.session_owner(session.id, state_dir: tmpdir)&.pid).to eq(@owner_pid)
  end
end
