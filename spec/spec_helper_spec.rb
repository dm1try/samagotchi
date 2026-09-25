# frozen_string_literal: true

# The suite's own isolation from the developer's shell and files.
RSpec.describe "spec_helper" do
  it "starts the suite without the shell's log settings" do
    expect(ENV.keys & %w[SAMAGOTCHI_LOG_FILE SAMAGOTCHI_LOG_LEVEL SAMAGOTCHI_LOG_DISABLE]).to eq([])
  end

  it "keeps config and state in temp dirs" do
    expect(ENV["XDG_CONFIG_HOME"]).to eq(SPEC_XDG_CONFIG_HOME)
    expect(ENV["XDG_STATE_HOME"]).to eq(SPEC_XDG_STATE_HOME)
  end
end
