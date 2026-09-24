# frozen_string_literal: true

require "tmpdir"
require "samagotchi/engine"

# recap.host_ref points the recap at a configured host: its OpenAI base
# (the url as written, else root/v1) and its API key variable.
RSpec.describe "Engine recap on a configured host", :recap do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { name: "box", host: "box.test", port: 8081 },
      "fw" => { name: "fw", host: "api.example.test", port: 443, scheme: "https", api: :openai,
                url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY" }
    })
  end

  def recap_for(host)
    Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "box:m",
                           recap: { host_ref: host, model: "#{host}:small" }).recap.target
  end

  it "uses a remote host's url and key variable" do
    expect(recap_for("fw")).to include(base_url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY", model: "small")
  end

  it "says in the session state whether recap is on, and when it would run (for an attached /recap)" do
    engine = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "box:m",
                                    recap: { host_ref: "box", model: "box:small" })
    off = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "box:m", recap: false)

    expect(engine.session_state_snapshot).to include(recap_enabled: true, recap_min_user_turns: engine.recap.min_user_turns,
                                                     recap_inactivity_seconds: engine.recap.inactivity.to_i)
    expect(off.session_state_snapshot).to include(recap_enabled: false, recap_min_user_turns: nil)
  end

  it "uses an explicit recap host and model for every attempt" do
    engine = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "box:m",
                                    recap: { host_ref: "fw", model: "fw:small" })
    expect(engine.recap.target).to eq(base_url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY",
                                      model: "small", label: "fw:small")
  end

  describe "with no recap config" do
    it "recaps with the session's own model on its host" do
      engine = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "fw:big")
      expect(engine.recap).not_to be_nil
      expect(engine.recap.target).to eq(base_url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY",
                                        model: "big", label: "fw:big")
    end

    it "follows a /model switch at the next attempt" do
      engine = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "fw:big")
      engine.instance_variable_set(:@effective_model_name, "box:m")
      expect(engine.recap.target).to include(base_url: "http://box.test:8081/v1", api_key_env: nil, model: "m")
    end

    it "honours a scalar `recap: false` in the config file (the worker passes no recap:)" do
      Dir.mktmpdir("samagotchi-config") do |dir|
        FileUtils.mkdir_p(File.join(dir, "samagotchi"))
        File.write(File.join(dir, "samagotchi", "config.yml"), "default:\n  model: spec-model\nrecap: false\n")
        old = ENV["XDG_CONFIG_HOME"]
        ENV["XDG_CONFIG_HOME"] = dir
        engine = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "box:m")
        expect(engine.recap).to be_nil
      ensure
        ENV["XDG_CONFIG_HOME"] = old
      end
    end

    it "takes recap.inactivity from the config without a host or model" do
      old = ENV["SAMAGOTCHI_RECAP_INACTIVITY"]
      ENV["SAMAGOTCHI_RECAP_INACTIVITY"] = "7"
      engine = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "box:m")
      expect(engine.recap.inactivity).to eq(7.0)
    ensure
      old.nil? ? ENV.delete("SAMAGOTCHI_RECAP_INACTIVITY") : ENV["SAMAGOTCHI_RECAP_INACTIVITY"] = old
    end

    it "still warns and stays off for an incomplete explicit config" do
      expect {
        engine = Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: "box:m", recap: { model: "small" })
        expect(engine.recap).to be_nil
      }.to output(/base_url\/model are missing/).to_stderr
    end
  end

  it "uses a local host's /v1" do
    expect(recap_for("box")).to include(base_url: "http://box.test:8081/v1", api_key_env: nil)
  end
end
