# frozen_string_literal: true

require "samagotchi/engine"
require "support/thinking_off"
require "support/test_kernel"

# execute.description: on by default; off, execute declares no description
# parameter in the session's prompt (and nothing else changes).
RSpec.describe Samagotchi::Engine, "execute.description" do
  include_context "thinking off"

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }

  before { allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([]) }

  def prompt(env)
    with_env({ "SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it" }.merge(env)) do
      described_class.new(client: client, kernel: kernel, profile: "gemma4").system_prompt
    end
  end

  it "declares execute's description by default and not with the setting off" do
    expect(prompt({})).to include("What this command does")
    off = prompt("SAMAGOTCHI_EXECUTE_DESCRIPTION" => "false")
    expect(off).not_to include("What this command does")
    expect(off).to include("declaration:execute{")
  end
end
