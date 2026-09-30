# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"

RSpec.describe "chi --new-token" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }

  it "goes with chi web only, and touches no token without it" do
    Dir.mktmpdir do |state|
      _out, err, status = Open3.capture3({ "XDG_STATE_HOME" => state }, RbConfig.ruby, chi, "--new-token", stdin_data: "")

      expect(status.exitstatus).to eq(1)
      expect(err).to eq("Error: --new-token goes with chi web (chi web --new-token)\n")
      expect(File.exist?(File.join(state, "samagotchi", "web-token"))).to be false
    end
  end
end
