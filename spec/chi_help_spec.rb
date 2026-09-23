# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "chi --help" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }

  it "says -p runs the prompt and stays in the REPL, and --non-interactive exits" do
    out, _err, status = Open3.capture3(RbConfig.ruby, chi, "--help", stdin_data: "")

    expect(status.exitstatus).to eq(0)
    prompt_line = out.lines.find { |l| l.include?("--prompt") }
    expect(prompt_line).to include("then stay in the REPL")
    expect(prompt_line).not_to include("exit")
    expect(out.lines.find { |l| l.include?("--non-interactive ") }).to include("exit")
  end
end
