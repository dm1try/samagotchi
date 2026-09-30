# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/idle_recap"

# The CLI examples that drove chi through PtyConsole are gone: nothing
# answered its cursor queries. Drive the real TUI with the smoke-run
# skill's vt_drive.py instead.
RSpec.describe "idle session-recap integration", :integration do
  skip "Integration tests require RECAP_INTEGRATION=1" unless ENV["RECAP_INTEGRATION"]
  skip "Integration tests require a live recap model server" unless ENV["SAMAGOTCHI_RECAP_BASE_URL"] && ENV["SAMAGOTCHI_RECAP_MODEL"]

  describe "Engine + IdleRecap full chain" do
    let(:base_time) { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    let(:messages) do
      [
        { "role" => "user", "content" => "Hi there, I'm working on a Ruby project." },
        { "role" => "assistant", "content" => "Hello! What can I help you with?" },
        { "role" => "user", "content" => "I need to refactor the auth module." }
      ]
    end
    let(:recap_events) { [] }
    let(:base_url) { ENV.fetch("SAMAGOTCHI_RECAP_BASE_URL", "http://localhost:8080/v1") }
    let(:model) { ENV.fetch("SAMAGOTCHI_RECAP_MODEL", "gemma-small") }

    let(:engine) do
      Samagotchi::Engine.new(
        recap: {
          base_url: base_url,
          model: model,
          inactivity: 0.0,
          timeout: 10.0
        }
      )
    end

    let(:client) { Samagotchi::IdleClient.new(model: model, base_url: base_url) }

    around do |example|
      engine.instance_variable_get(:@session_observer)&.subscribe(
        observer: ->(event) { recap_events << event if event[:type] == :recap_ready }
      )
      example.run
      recap_events.clear
    end

    it "emits a :recap_ready event when the full chain fires with a real model" do
      engine.start_idle
      allow(engine).to receive(:turn_running?).and_return(false)
      allow(engine).to receive(:last_activity_at).and_return(base_time - 60)
      allow(engine).to receive(:activity_seq).and_return(2)
      allow(engine).to receive(:messages_json_for_recap).and_return(
        JSON.generate(messages)
      )
      engine.recap.tick
      (sleep 0.2; engine.recap.tick) until recap_events.any? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > base_time + 15
      engine.stop_idle

      expect(recap_events).not_to be_empty
      event = recap_events.first
      expect(event[:type]).to eq(:recap_ready)
      expect(event[:recap]).not_to be_nil
      expect(event[:recap].to_s.strip).not_to be_empty
      expect(event[:generation]).to be_a(Integer)
      expect(event[:generation]).to be >= 1
    end
  end
end