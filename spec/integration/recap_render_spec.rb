# frozen_string_literal: true
require "samagotchi/engine"
require "samagotchi/idle_recap"
require "samagotchi/terminal_ui"
require_relative "../support/pty_console"
RSpec.describe "idle session-recap integration" do
  skip "PTY tests require RECAP_INTEGRATION=1" unless ENV["RECAP_INTEGRATION"]
  skip "PTY flaky on CI" if ENV["CI"]
  let(:base_time) { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  let(:messages) do
    [
      { "role" => "user", "content" => "Hi there, I'm working on a Ruby project." },
      { "role" => "assistant", "content" => "Hello! What can I help you with?" },
      { "role" => "user", "content" => "I need to refactor the auth module." }
    ]
  end
  describe "Engine + IdleRecap full chain" do
    before { skip "Requires live model server" unless ENV["LLAMA_INTEGRATION"] == "1" }
    let(:base_url) { "http://localhost:8080/v1" }
    let(:model) { "gemma4-small" }
    let(:recap_events) { [] }
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
  describe "PTY + mock HTTP recap server" do
    it "renders the recap line when the mock server responds" do
      recap_response = {
        "choices" => [{
          "message" => {
            "role" => "assistant",
            "content" => "The user worked on a Ruby project and needed to refactor the auth module."
          }
        }]
      }.to_json
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      server_thread = Thread.new do
        begin
          client = server.accept
          $stdout.puts "MSS connected port=#{server.local_address.ip_port}"
          $stdout.flush
          req = ""
          loop { c = client.readpartial(4096); break unless c; req += c; break if req.include?("\r\n\r\n") }
          client.readpartial(1024) rescue EOFError
          client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{recap_response.bytesize}\r\n\r\n#{recap_response}\r\n")
          client.flush
          $stdout.puts "MSS sent"
          $stdout.flush
        rescue StandardError => e
          $stdout.puts "MSS error: #{e.class}: #{e.message}"
          $stdout.flush
        ensure
          client&.close; server.close rescue nil
        end
      end
      sleep 0.3
      console = Samagotchi::PtyConsole.spawn(
        command: "bundle exec ruby -Ilib tmp/chi_debug.rb",
        env: {
          "SAMAGOTCHI_RECAP_BASE_URL" => "http://127.0.0.1:#{port}/v1",
          "SAMAGOTCHI_RECAP_MODEL" => "gemma4-small",
          "SAMAGOTCHI_RECAP_INACTIVITY" => "0.0",
          "SAMAGOTCHI_RECAP_MIN_USER_TURNS" => "1",
          "SAMAGOTCHI_THINKING_UI" => "off",
          "SAMAGOTCHI_BACKEND" => "native",
          "PATH" => ENV.fetch("PATH")
        },
        winsize: [24, 80]
      )
      begin
        output = console.read_until(/recap>/, timeout: 45.0)
        expect(output).to match(/recap>/)
        expect(output).to match(/The user worked on a Ruby project/)
      ensure
        console.close!
        server_thread&.kill
        server_thread&.join(1)
        server.close rescue nil
      end
    end
    it "does not crash the session when the recap server is unreachable" do
      console = Samagotchi::PtyConsole.spawn(
        command: "bundle exec ruby -Ilib tmp/chi_debug.rb",
        env: {
          "SAMAGOTCHI_RECAP_BASE_URL" => "http://127.0.0.1:19999/v1",
          "SAMAGOTCHI_RECAP_MODEL" => "gemma4-small",
          "SAMAGOTCHI_RECAP_INACTIVITY" => "0.0",
          "SAMAGOTCHI_RECAP_MIN_USER_TURNS" => "1",
          "SAMAGOTCHI_THINKING_UI" => "off",
          "SAMAGOTCHI_BACKEND" => "native",
          "PATH" => ENV.fetch("PATH")
        },
        winsize: [24, 80]
      )
      begin
        output = console.read_until(/Session:/, timeout: 10.0)
        expect(output).to be_a(String)
        expect(output).to match(/Session:/)
      ensure
        console.close!
      end
    end
    it "does not render a recap line when recap is not configured" do
      console = Samagotchi::PtyConsole.spawn(
        command: "bundle exec ruby -Ilib tmp/chi_debug.rb",
        env: {
          "SAMAGOTCHI_THINKING_UI" => "off",
          "SAMAGOTCHI_BACKEND" => "native",
          "PATH" => ENV.fetch("PATH")
        },
        winsize: [24, 80]
      )
      begin
        output = console.read_until(/Session:/, timeout: 10.0)
        expect(output).not_to match(/recap>/)
        expect(output).to match(/Session:/)
      ensure
        console.close!
      end
    end
  end
end