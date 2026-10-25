# frozen_string_literal: true

require "tmpdir"
require "spec_helper"

# `chi web push` through bin/chi: the branch before RunOptions (which would
# refuse `push` as an unexpected argument). PushCommand's spec has the rest.
RSpec.describe "chi web push (CLI)" do
  let(:tmp) { Dir.mktmpdir("chi-web-push") }

  after { FileUtils.rm_rf(tmp) }

  it "lists no devices on an empty store, and a usage error exits 2" do
    out, err, status = run_chi("web", "push", "ls", env: isolated_chi_env(tmp))
    expect([out, err, status.exitstatus]).to eq(["no devices (turn the bell on in the phone's Home Screen app)\n", "", 0])

    _, err, status = run_or_fork_chi("web", "push", "rm", spawn: false, env: isolated_chi_env(tmp))
    expect([err, status.exitstatus]).to eq(["chi web push rm: give one device ID (chi web push ls) (see chi web push rm --help)\n", 2])
  end
end
