# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/dashboard"

RSpec.describe Samagotchi::Dashboard do
  # The interactive Dashboard is temporarily a minimal no-crash shim while the
  # multi-agent / engines UI is being reworked (see tmp/plans/). This spec
  # asserts the shim: it loads, prints a "reworked" notice, and exits cleanly.
  describe "#run" do
    it "prints a reworked notice pointing at the plan and returns cleanly" do
      dashboard = described_class.new

      expect {
        dashboard.run
      }.to output(/reworked/i).to_stdout

      # Notice should point at the plan so users can find the roadmap.
      expect {
        dashboard.run
      }.to output(/tmp\/plans/i).to_stdout
    end

    it "returns normally without exiting the process" do
      dashboard = described_class.new
      expect { dashboard.run }.not_to raise_error
      expect { dashboard.run }.not_to raise_error(SystemExit)
    end
  end
end
