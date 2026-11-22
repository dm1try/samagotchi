# frozen_string_literal: true

require "samagotchi/agent_caller"

RSpec.describe Samagotchi::AgentCaller do
  describe ".send_id" do
    it "is chi send's id: the owner's row" do
      expect(described_class.send_id).to eq(Samagotchi::ClientId::CLI_SEND)
    end
  end
end

RSpec.describe "ClientId.parent_line?" do
  it "is chi send's and chi answer's line, nothing else" do
    expect(%w[cli:send cli:answer].map { |id| Samagotchi::ClientId.parent_line?(id) }).to all(be(true))
    expect([nil, "", "web:ab12", "tui:1", "cli:restart", "delegate:1234abcd", "plugin"]
             .map { |id| Samagotchi::ClientId.parent_line?(id) }).to all(be(false))
  end
end
