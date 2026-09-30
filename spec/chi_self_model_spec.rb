# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

# The desktop helper asks `chi self --model` for the model a new session
# starts on (its "New session" row's hint).
RSpec.describe "chi self --model" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }
  let(:tmp) { Dir.mktmpdir("chi-self-model") }
  let(:env) do
    { "XDG_CONFIG_HOME" => File.join(tmp, "config"), "XDG_STATE_HOME" => File.join(tmp, "state"), "HOME" => tmp,
      "SAMAGOTCHI_DEFAULT_MODEL" => nil }
  end

  after { FileUtils.remove_entry(tmp) }

  def run_chi(*args)
    Open3.capture3(env, RbConfig.ruby, chi, *args, stdin_data: "")
  end

  it "prints only the configured default model" do
    FileUtils.mkdir_p(File.join(tmp, "config", "samagotchi"))
    File.write(File.join(tmp, "config", "samagotchi", "config.yml"), "default:\n  model: spec-model\n")

    out, _err, status = run_chi("self", "--model")

    expect(status.exitstatus).to eq(0)
    expect(out).to eq("spec-model\n")
  end

  it "prints nothing and exits 1 when no model is configured" do
    out, _err, status = run_chi("self", "--model")

    expect(status.exitstatus).to eq(1)
    expect(out).to eq("")
  end
end
