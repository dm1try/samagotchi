# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "support/bounded_capture"

# A first run with no config at all: one line naming config.yml's
# default.model, not a backtrace, whichever way the session would start.
RSpec.describe "chi without a configured model" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }
  let(:home) { Dir.mktmpdir("chi-first-run") }
  let(:env) do
    { "HOME" => home, "XDG_CONFIG_HOME" => File.join(home, "config"), "XDG_STATE_HOME" => File.join(home, "state"),
      "SAMAGOTCHI_DEFAULT_MODEL" => nil, "SAMAGOTCHI_SESSION_SHARED" => nil }
  end

  after { FileUtils.rm_rf(home) }

  [[], ["--no-shared"], ["-p", "hi", "--non-interactive"]].each do |args|
    it "says where to set the model (chi #{args.join(" ")})".rstrip do
      _out, err, status = BoundedCapture.capture3(env, RbConfig.ruby, chi, *args, stdin_data: "", timeout: 20)

      expect(status.exitstatus).to eq(1)
      expect(err).to eq("Error: no model configured: set default.model in #{home}/config/samagotchi/config.yml " \
                        "to the model id your server serves (or SAMAGOTCHI_DEFAULT_MODEL, or pass --model ID); " \
                        "see docs/configuration.md; or run: chi bootstrap HOST[:PORT]\n")
    end
  end
end
