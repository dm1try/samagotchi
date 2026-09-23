# frozen_string_literal: true

require "samagotchi/engine"

# recap.host_ref points the recap at a configured host: its OpenAI base
# (the url as written, else root/v1) and its API key variable.
RSpec.describe "Engine recap on a configured host" do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { name: "box", host: "box.test", port: 8081 },
      "fw" => { name: "fw", host: "api.example.test", port: 443, scheme: "https", api: :openai,
                url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY" }
    })
  end

  def recap_for(host)
    allow(Samagotchi::IdleRecap).to receive(:new).and_call_original
    Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "box:m",
                           recap: { host_ref: host, model: "#{host}:small" })
    Samagotchi::IdleRecap
  end

  it "uses a remote host's url and key variable" do
    expect(recap_for("fw")).to have_received(:new)
      .with(hash_including(base_url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY", model: "small"))
  end

  it "says in the session state whether recap is on, and when it would run (for an attached /recap)" do
    engine = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "box:m",
                                    recap: { host_ref: "box", model: "box:small" })
    off = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "box:m")

    expect(engine.session_state_snapshot).to include(recap_enabled: true, recap_min_user_turns: engine.recap.min_user_turns,
                                                     recap_inactivity_seconds: engine.recap.inactivity.to_i)
    expect(off.session_state_snapshot).to include(recap_enabled: false, recap_min_user_turns: nil)
  end

  it "uses a local host's /v1" do
    expect(recap_for("box")).to have_received(:new).with(hash_including(base_url: "http://box.test:8081/v1", api_key_env: nil))
  end
end
