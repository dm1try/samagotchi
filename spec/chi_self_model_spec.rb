# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# The desktop helper asks `chi self --model` for the model a new session
# starts on (its "New session" row's hint).
RSpec.describe "chi self --model" do
  let(:tmp) { Dir.mktmpdir("chi-self-model") }
  let(:env) { isolated_chi_env(tmp) }

  after { FileUtils.remove_entry(tmp) }

  def run_chi(*args)
    super(*args, env: env)
  end

  it "prints only the configured default model" do
    FileUtils.mkdir_p(File.join(tmp, "config", "samagotchi"))
    File.write(File.join(tmp, "config", "samagotchi", "config.yml"), "default:\n  model: spec-model\n")

    out, _err, status = run_chi("self", "--model")

    expect(status.exitstatus).to eq(0)
    expect(out).to eq("spec-model\n")
  end

  it "prints an alias default as the ref it resolves to, as `chi models` names it" do
    FileUtils.mkdir_p(File.join(tmp, "config", "samagotchi"))
    File.write(File.join(tmp, "config", "samagotchi", "config.yml"),
               "default:\n  model: small\nhosts:\n  default:\n    host: 127.0.0.1\n    port: 1\n  box:\n    host: 127.0.0.1\n    port: 2\n" \
               "model_aliases:\n  small: BOX:gemma-small\n")

    out, _err, status = run_chi("self", "--model")

    expect(status.exitstatus).to eq(0)
    expect(out).to eq("box:gemma-small\n")
  end

  it "prints nothing and exits 1 when no model is configured" do
    out, _err, status = run_chi("self", "--model")

    expect(status.exitstatus).to eq(1)
    expect(out).to eq("")
  end
end
