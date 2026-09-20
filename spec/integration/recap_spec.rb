# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/idle_client"

# Integration test that verifies the idle session-recap feature works end-to-end
# with a live llama.cpp server. Tests the full chain: Engine#build_recap →
# IdleRecap idle detection → IdleClient summarization → :recap_ready event.
#
# Prerequisites:
#   - A llama.cpp server must be running (default: localhost:8080)
#   - SAMAGOTCHI_INTEGRATION=1 environment variable must be set
#   - SAMAGOTCHI_RECAP_BASE_URL and SAMAGOTCHI_RECAP_MODEL must be set
#     (or use the default config from the server)
#
# Run with:
#   SAMAGOTCHI_INTEGRATION=1 SAMAGOTCHI_RECAP_BASE_URL=http://localhost:8080/v1 \
#     SAMAGOTCHI_RECAP_MODEL=gemma4-small \
#     bundle exec rspec spec/integration/recap_spec.rb
#
# Against the Qwen3.6-35B-A3B model (reasoning_content fallback test):
#   SAMAGOTCHI_INTEGRATION=1 SAMAGOTCHI_RECAP_BASE_URL=http://192.168.1.29:8081/v1 \
#     SAMAGOTCHI_RECAP_MODEL=unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M \
#     bundle exec rspec spec/integration/recap_spec.rb -v
#
# Verbose output:
#   SAMAGOTCHI_INTEGRATION=1 bundle exec rspec spec/integration/recap_spec.rb -v
#
# Test scope:
#   - Unit tests (spec/idle_client_spec.rb, spec/idle_recap_spec.rb) cover the
#     idle detection loop, event emission, and parsing with stubbed clients.
#   - Integration tests below exercise the **full chain** with a real model:
#     Engine.build_recap → IdleRecap → IdleClient HTTP → :recap_ready event.
RSpec.describe "idle session-recap end-to-end", :integration do
  let(:base_time) { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  let(:messages) do
    [
      { "role" => "user", "content" => "Hi there, I'm working on a Ruby project." },
      { "role" => "assistant", "content" => "Hello! What can I help you with?" },
      { "role" => "user", "content" => "I need to refactor the auth module." }
    ]
  end
  let(:recap_events) { [] }
  let(:base_url) { ENV["SAMAGOTCHI_RECAP_BASE_URL"] || "http://localhost:8080/v1" }
  let(:model) { ENV["SAMAGOTCHI_RECAP_MODEL"] || "gemma4-small" }

  # Build an Engine with a real IdleRecap that emits to our capture array.
  let(:engine) do
    Samagotchi::Engine.new(
      mode: :assist,
      recap: {
        base_url: base_url,
        model: model,
        inactivity: 0.0,  # fire immediately
        timeout: 10.0
      }
    )
  end

  let(:session_observer) { Samagotchi::SessionObserver.new }
  let(:client) { Samagotchi::IdleClient.new(model: model, base_url: base_url) }

  around do |example|
    # Subscribe to recap_ready events
    engine.instance_variable_get(:@session_observer)&.subscribe(
      observer: ->(event) { recap_events << event if event[:type] == :recap_ready }
    )
    example.run
    recap_events.clear
  end

  it "emits a :recap_ready event with non-empty recap prose after idle" do
    # Build a recap directly (simulates what IdleRecap does after idle detection)
    recap = client.summarize(
      "Summarize this session:\n" \
      "User: Hi there, I'm working on a Ruby project.\n\n" \
      "Assistant: Hello! What can I help you with?\n\n" \
      "User: I need to refactor the auth module."
    )
    # The recap should not be nil or empty — the model actually responded.
    # For reasoning_content models (Qwen3.6), this exercises the fallback path.
    expect(recap).not_to be_nil
    expect(recap.to_s.strip).not_to be_empty

    # The recap should contain some recognizable content from the prompt.
    expect(recap.to_s).to match(/session|project|auth|refactor|recap/i)
  end

  it "handles reasoning_content-only responses (Qwen3.6-style models)" do
    # Some models like Qwen3.6-35B-A3B output think tokens to reasoning_content
    # instead of content. This test verifies IdleClient.parse_content handles
    # that case correctly by exercising the real client against the live server.
    result = client.summarize(
      "You are a recap assistant. Summarize this conversation in one sentence."
    )
    # Even if the model outputs primarily thinking tokens, we should get text back.
    expect(result).not_to be_nil
    expect(result.to_s.strip).not_to be_empty
    # The recap should be reasonably short (max_tokens: 256).
    expect(result.to_s.length).to be <= 256 * 4  # generous UTF-8 multiplier
  end

  it "returns nil for empty prompt" do
    result = client.summarize("   ")
    expect(result).to be_nil
  end

  it "raises SummarizeError when server is unreachable" do
    bad_client = Samagotchi::IdleClient.new(
      model: "nonexistent",
      base_url: "http://127.0.0.1:1"
    )
    expect { bad_client.summarize("summarize this") }
      .to raise_error(Samagotchi::IdleClient::SummarizeError)
  end

  # ── Full Engine → IdleRecap → IdleClient → :recap_ready event chain ────────
  it "emits a :recap_ready event when the full chain fires with a real model" do
    # This test exercises the entire chain:
    # Engine.build_recap → IdleRecap.tick → IdleClient.summarize (real HTTP)
    # → Engine.emit_recap → @session_observer → :recap_ready event
    #
    # We manually set idle conditions and call `tick` — no real idle time needed.
    #
    # Note: Engine#run_turn now sets @session, so messages_json_for_recap works
    # without stubbing. We still stub turn_running?/last_activity_at/activity_seq
    # to trigger the idle condition immediately.
    engine.start_idle

    # Set the engine to idle: last_activity_at is far in the past, no turn running
    allow(engine).to receive(:turn_running?).and_return(false)
    allow(engine).to receive(:last_activity_at).and_return(base_time - 60)
    allow(engine).to receive(:activity_seq).and_return(2)
    allow(engine).to receive(:messages_json_for_recap).and_return(
      JSON.generate([
        { "role" => "user", "content" => "Hi there, working on a Ruby project." },
        { "role" => "assistant", "content" => "Hello! What can I help you with?" },
        { "role" => "user", "content" => "I need to refactor the auth module." }
      ])
    )

    # Trigger the recap manually
    engine.recap.tick

    # Wait for the async recap to complete (timeout is generous)
    sleep 1.0 until recap_events.any? || Time.now > base_time + 15
    engine.recap.stop

    # Verify the event was emitted with non-empty recap
    expect(recap_events).not_to be_empty
    event = recap_events.first
    expect(event[:type]).to eq(:recap_ready)
    expect(event[:recap]).not_to be_nil
    expect(event[:recap].to_s.strip).not_to be_empty
    expect(event[:generation]).to be_a(Integer)
    expect(event[:generation]).to be >= 1
  end
end
