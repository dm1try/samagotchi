# frozen_string_literal: true

require "samagotchi/child_env"

RSpec.describe Samagotchi::ChildEnv do
  let(:env) do
    { "SAMAGOTCHI_GUARDRAILS_RULES" => "deny", "SAMAGOTCHI_PARENT_SESSION" => "parent",
      "SAMAGOTCHI_INSTALLED_VERSION" => "9.9.9", "SAMAGOTCHI_DEFAULT_MODEL" => "kept", "PATH" => "/bin" }
  end

  it "lists the spawner's guardrails settings, session markers, fake installed version and project env marker" do
    expect(described_class.spawner_keys(env)).to include("SAMAGOTCHI_GUARDRAILS_RULES", "SAMAGOTCHI_PARENT_SESSION",
                                                         "SAMAGOTCHI_SESSION_MODEL", "SAMAGOTCHI_INSTALLED_VERSION",
                                                         "SAMAGOTCHI_PROJECT_ENV")
    expect(described_class.spawner_keys(env)).not_to include("SAMAGOTCHI_DEFAULT_MODEL", "PATH")
  end

  it "unsets them for Process.spawn and scrubs them from a copy" do
    expect(described_class.unset(env)).to include("SAMAGOTCHI_GUARDRAILS_RULES" => nil,
                                                  "SAMAGOTCHI_PARENT_SESSION" => nil)
    expect(described_class.scrub(env)).to eq("SAMAGOTCHI_DEFAULT_MODEL" => "kept", "PATH" => "/bin")
    expect(env).to include("SAMAGOTCHI_PARENT_SESSION" => "parent")
  end
end
