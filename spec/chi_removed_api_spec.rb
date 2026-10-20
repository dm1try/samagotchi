# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A config.yml still naming chi's removed mlx/omlx transports stops chi at
# start with one line saying what to write instead (ConfigFile::RemovedApi).
RSpec.describe "chi with a config naming api: omlx" do
  let(:home) { Dir.mktmpdir("chi-removed-api") }

  after { FileUtils.rm_rf(home) }

  it "exits 1 with the one line" do
    FileUtils.mkdir_p(File.join(home, "config", "samagotchi"))
    File.write(File.join(home, "config", "samagotchi", "config.yml"),
               "default:\n  model: m\nhosts:\n  mac:\n    url: http://mac:8000\n    api: omlx\n")

    out, err, status = run_chi("-p", "hi", "--non-interactive", env: isolated_chi_env(home), timeout: 20)

    expect(status.exitstatus).to eq(1)
    expect(out).to eq("")
    expect(err).to eq("Error: config.yml hosts.mac.api: omlx was removed; for mlx_lm.server or oMLX use " \
                      "url: http://HOST:PORT/v1, api: openai in a hosts: entry\n")
  end
end
