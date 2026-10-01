# frozen_string_literal: true

require "spec_helper"

# `chi web`'s flags go through OptionParser, which permutes: the ones after
# `web` are parsed like the ones before it. Flags it can't see (after `--`,
# or with POSIXLY_CORRECT set) are stray arguments. chi_help_spec covers a
# plain stray word after web. Bounded: a case that got past the checks would
# start the server.
RSpec.describe "chi web arguments" do

  def run_chi(*args, env: {})
    out, err, status = super(*args, env: env, timeout: 10)
    [out, err, status.exitstatus]
  end

  it "refuses a flag after --" do
    expect(run_chi("web", "--", "--port", "5")).to eq(["", "Error: unexpected argument --port (see chi --help)\n", 1])
  end

  it "refuses a flag after web when POSIXLY_CORRECT stops the permuting" do
    expect(run_chi("web", "--port", "5", env: { "POSIXLY_CORRECT" => "1" }))
      .to eq(["", "Error: unexpected argument --port (see chi --help)\n", 1])
  end

  it "refuses an unknown --web-view value after web" do
    expect(run_chi("web", "--web-view", "bogus")).to eq(["", "Error: invalid argument: --web-view bogus (see chi --help)\n", 1])
    expect(run_chi("web", "--web-view=bogus")).to eq(["", "Error: invalid argument: --web-view=bogus (see chi --help)\n", 1])
  end
end
