# frozen_string_literal: true

require "open3"
require "rbconfig"

# --thinking LEVEL: the run's thinking level (thinking.level), outranking
# config.yml; bin/chi copies it into SAMAGOTCHI_THINKING_LEVEL for workers.
RSpec.describe "chi --thinking" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }

  it "refuses a value that isn't a level" do
    _out, err, status = Open3.capture3(RbConfig.ruby, chi, "--thinking", "on", "--help", stdin_data: "")

    expect(status.exitstatus).not_to eq(0)
    expect(err).to include("--thinking on")
  end

  it "is listed in --help with its levels" do
    out, = Open3.capture3(RbConfig.ruby, chi, "--help", stdin_data: "")

    expect(out).to include("--thinking LEVEL")
    expect(out).to include("off|low|medium|high|default")
  end
end
