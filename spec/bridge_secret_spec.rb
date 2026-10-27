# frozen_string_literal: true

require "spec_helper"
require "samagotchi/bridge_secret"

RSpec.describe Samagotchi::BridgeSecret do
  describe ".refused" do
    it "names the session and prints commands for the invocation's machine" do
      via = Samagotchi::ChiInvocation.new(remote: "studio")

      words = described_class.refused("s-1234", via: via)

      expect(words).to include("session s-1234's worker refused this chi's request")
      expect(words).to include(via.command("--attach s-1234"))
      expect(words).to include(via.command("sessions restart s-1234"))
      expect(words).not_to include(" ID")
    end
  end
end
