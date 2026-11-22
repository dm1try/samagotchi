# frozen_string_literal: true

require "samagotchi/agent_caller"
require "samagotchi/guardrails/parent_approvals"
require "samagotchi/session_inbox"

RSpec.describe Samagotchi::AgentCaller do
  let(:sid) { "0b9e1c2a-1111-4222-8333-444455556666" }

  describe ".name" do
    it "is nil for the owner: no marker, no --as (a pipe alone is not one)" do
      expect(described_class.name(env: {})).to be_nil
      expect(described_class.name(env: { "CLAUDECODE" => " " })).to be_nil
    end

    it "takes chi's own marker first, even over --as and CLAUDECODE (a worker inherits its spawner's)" do
      expect(described_class.name(env: { "CLAUDECODE" => "1", "SAMAGOTCHI_PARENT_SESSION" => sid })).to eq("chi-0b9e1c2a")
      expect(described_class.name(env: { "SAMAGOTCHI_PARENT_SESSION" => sid }, as: "bob")).to eq("chi-0b9e1c2a")
      # A run with no session (Tools::Builtins.parent_env's "chi"), or anything not an id.
      expect(described_class.name(env: { "SAMAGOTCHI_PARENT_SESSION" => "chi" })).to eq("chi")
    end

    it "then --as, then CLAUDECODE, CODEX_THREAD_ID and AI_AGENT, in that order" do
      env = { "CLAUDECODE" => "1", "CODEX_THREAD_ID" => "t-1", "AI_AGENT" => "cursor" }
      expect(described_class.name(env: env, as: "builder")).to eq("builder")
      expect(described_class.name(env: env)).to eq("claude")
      expect(described_class.name(env: env.except("CLAUDECODE"))).to eq("codex")
      expect(described_class.name(env: { "AI_AGENT" => "Cursor" })).to eq("cursor")
      # A value that is no name is dropped: the fallback name.
      expect(described_class.name(env: { "AI_AGENT" => "a b]\n[c" })).to eq("agent")
    end

    it "reads the same markers the guardrails read" do
      expect(described_class::PARENT_SESSION).to eq(Samagotchi::Guardrails::ParentApprovals::PARENT_SESSION_ENV)
      expect(described_class::VENDOR_MARKERS.map(&:first) + [described_class::PARENT_SESSION])
        .to match_array(Samagotchi::Guardrails::ParentApprovals::AGENT_MARKERS)
    end
  end

  describe ".clean" do
    it "takes lowercase letters, digits, - and _, 1 to 32 characters; anything else is nil" do
      expect(described_class.clean(" Claude ")).to eq("claude")
      expect(described_class.clean("chi-0b9e1c2a_x")).to eq("chi-0b9e1c2a_x")
      expect(["", "a b", "x]", "é", "a" * 33, nil].map { |name| described_class.clean(name) }).to all(be_nil)
    end
  end

  describe ".send_id / .continue_id" do
    it "is the agent's id with a name, chi send's without" do
      expect(described_class.send_id).to eq(Samagotchi::ClientId::CLI_SEND)
      expect(described_class.send_id(name: "claude")).to eq("agent:claude")
    end

    it "sends a parent line's /continue yes as chi answer's, any other id as given" do
      expect(%w[cli:send cli:answer agent:claude].map { |id| described_class.continue_id(id) }).to all(eq("cli:answer"))
      expect(%w[web:ab tui:1 web:unnamed].map { |id| described_class.continue_id(id) }).to eq(%w[web:ab tui:1 web:unnamed])
    end
  end
end

RSpec.describe "ClientId.parent_line? / the agent row" do
  ids = Samagotchi::ClientId

  it "is chi send's, chi answer's and an agent's line, nothing else" do
    expect(%w[cli:send cli:answer agent:claude].map { |id| ids.parent_line?(id) }).to all(be(true))
    expect([nil, "", "web:ab12", "tui:1", "cli:restart", "delegate:1234abcd", "plugin"]
             .map { |id| ids.parent_line?(id) }).to all(be(false))
  end

  it "names an agent's id and cleans its name again as it is read" do
    expect(ids.agent("claude")).to eq("agent:claude")
    expect([ids.agent?("agent:claude"), ids.agent?("cli:send"), ids.agent?(nil)]).to eq([true, false, false])
    expect(ids.agent_name("agent:Cl aude]\n")).to eq("claude")
    expect(ids.agent_name("agent:")).to eq("agent")
    expect(ids.agent_name("agent:#{"x" * 40}")).to eq("x" * 32)
    expect(ids.agent_name("cli:send")).to be_nil
  end

  it "is unattended: it starts an idle session, never a stopped or archived one" do
    policy = Samagotchi::SessionInbox::WakePolicy.for(ids.wake_kind("agent:claude"))
    expect(policy).to have_attributes(starts: true, unstops: false, starts_archived: false, resolves: :pinned)
  end
end
