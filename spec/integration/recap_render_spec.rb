# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/idle_recap"
require_relative "../support/pty_console"

RSpec.describe "idle session-recap CLI integration", :integration do
  skip "Integration tests require RECAP_INTEGRATION=1" unless ENV["RECAP_INTEGRATION"]
  skip "Integration tests require a live recap model server" unless ENV["SAMAGOTCHI_RECAP_BASE_URL"] && ENV["SAMAGOTCHI_RECAP_MODEL"]

  let(:recap_base_url) { ENV.fetch("SAMAGOTCHI_RECAP_BASE_URL", nil) }
  let(:recap_model) { ENV.fetch("SAMAGOTCHI_RECAP_MODEL", nil) }
  let(:recap_inactivity) { ENV.fetch("SAMAGOTCHI_RECAP_INACTIVITY", "2.0") }
  let(:recap_min_user_turns) { ENV.fetch("SAMAGOTCHI_RECAP_MIN_USER_TURNS", "2") }
  let(:recap_timeout) { ENV.fetch("SAMAGOTCHI_RECAP_TIMEOUT", "15.0") }

  # Default env for the chi process — override in specific tests.
  let(:base_env) do
    {
      "SAMAGOTCHI_RECAP_BASE_URL" => recap_base_url,
      "SAMAGOTCHI_RECAP_MODEL" => recap_model,
      "SAMAGOTCHI_RECAP_INACTIVITY" => recap_inactivity,
      "SAMAGOTCHI_RECAP_MIN_USER_TURNS" => recap_min_user_turns,
      "SAMAGOTCHI_RECAP_TIMEOUT" => recap_timeout,
      "SAMAGOTCHI_THINKING_UI" => "off",
      "SAMAGOTCHI_BACKEND" => "native",
      "PATH" => ENV.fetch("PATH")
    }
  end

  describe "/recap command" do
    it "displays a recap after idle inactivity with /recap command" do
      console = Samagotchi::PtyConsole.spawn(
        command: "bundle exec bin/chi",
        env: base_env,
        winsize: [24, 80]
      )

      begin
        # Wait for the session banner
        output = console.read_until(/Session:/, timeout: 15.0)
        expect(output).to match(/Session:/)

        # Send first user turn
        console.write("hello")

        # Wait for the model response
        output = console.read_until(/>/, timeout: 15.0)
        expect(output).to match(/>/)

        # Send second user turn
        console.write("how are you?")

        # Wait for the model response
        output = console.read_until(/>/, timeout: 15.0)
        expect(output).to match(/>/)

        # Wait for inactivity timeout — the recap detector should fire
        # and generate a summary. Then send /recap to display it.
        sleep(recap_inactivity.to_f + 2.0)
        console.write("/recap")

        # Wait for the recap output — should contain "session recap:"
        output = console.read_until(/session recap:/, timeout: 30.0)
        expect(output).to match(/session recap:/)
        expect(output).to match(/recap/)
      ensure
        console.close!
      end
    end

    it "shows a helpful message when no recap is available yet" do
      console = Samagotchi::PtyConsole.spawn(
        command: "bundle exec bin/chi",
        env: base_env,
        winsize: [24, 80]
      )

      begin
        # Wait for the session banner
        output = console.read_until(/Session:/, timeout: 15.0)
        expect(output).to match(/Session:/)

        # Send just one user turn — below min_user_turns threshold
        console.write("hello")

        # Wait for the model response
        output = console.read_until(/>/, timeout: 15.0)
        expect(output).to match(/>/)

        # Send /recap — should indicate no recap available yet
        console.write("/recap")

        # Wait for the response — should mention min turns
        output = console.read_until(/no recap available|min.*turn|needs/, timeout: 10.0)
        expect(output).to match(/no recap available|min.*turn|needs/i)
      ensure
        console.close!
      end
    end

    it "does not show recap line when recap is not configured" do
      env = base_env.merge(
        "SAMAGOTCHI_RECAP_BASE_URL" => "",
        "SAMAGOTCHI_RECAP_MODEL" => ""
      )
      console = Samagotchi::PtyConsole.spawn(
        command: "bundle exec bin/chi",
        env: env,
        winsize: [24, 80]
      )

      begin
        output = console.read_until(/Session:/, timeout: 15.0)
        expect(output).to match(/Session:/)
        expect(output).not_to match(/recap>/)
      ensure
        console.close!
      end
    end

    it "does not crash when the recap server is unreachable" do
      env = base_env.merge(
        "SAMAGOTCHI_RECAP_BASE_URL" => "http://127.0.0.1:19999/v1",
        "SAMAGOTCHI_RECAP_MODEL" => "nonexistent",
        "SAMAGOTCHI_RECAP_INACTIVITY" => "0.5",
        "SAMAGOTCHI_RECAP_MIN_USER_TURNS" => "1",
        "SAMAGOTCHI_RECAP_TIMEOUT" => "3.0"
      )
      console = Samagotchi::PtyConsole.spawn(
        command: "bundle exec bin/chi",
        env: env,
        winsize: [24, 80]
      )

      begin
        # Wait for the session banner
        output = console.read_until(/Session:/, timeout: 10.0)
        expect(output).to match(/Session:/)

        # Send a turn — should complete without crashing even though recap server is down
        console.write("hello")

        # Wait for the model response
        output = console.read_until(/>/, timeout: 15.0)
        expect(output).to match(/>/)
      ensure
        console.close!
      end
    end
  end

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
    let(:model) { ENV.fetch("SAMAGOTCHI_RECAP_MODEL", "gemma4-small") }

    let(:engine) do
      Samagotchi::Engine.new(
        mode: :assist,
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
      engine.start_recap
      allow(engine).to receive(:turn_running?).and_return(false)
      allow(engine).to receive(:last_activity_at).and_return(base_time - 60)
      allow(engine).to receive(:activity_seq).and_return(2)
      allow(engine).to receive(:messages_json_for_recap).and_return(
        JSON.generate(messages)
      )
      engine.recap.tick
      sleep 1.0 until recap_events.any? || Time.now.to_f > base_time + 15
      engine.recap.stop

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