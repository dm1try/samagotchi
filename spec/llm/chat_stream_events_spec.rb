# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"

# The chat loop splits its own stream (reasoning arrives apart from the
# answer), so Engine must pass its generation_chunk text:/thinking: through
# instead of re-splitting the raw content with the profile's splitter, which
# for Qwen would overwrite them and for Gemma would leave the web lanes to
# guess from content (F11).
RSpec.describe "Engine and the chat loop's stream" do
  let(:registry) { Samagotchi::HostRegistry.new(hosts_config: { "oai" => { host: "oai.test", port: 8000, api: :openai } }) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "oai:m", working_directory: Dir.pwd) }

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

  %w[qwen36 gemma4].each do |profile|
    it "passes the chat loop's text and thinking through for a #{profile} model" do
      engine = Samagotchi::Engine.new(host_registry: registry, model_name: "oai:m", profile: profile)
      chat = engine.backend
      allow(chat).to receive(:complete) do |on_stream_event:, **|
        on_stream_event.call(type: :generation_started, iteration: 1)
        on_stream_event.call(type: :generation_chunk, iteration: 1, content: "planPONG", text: "PONG", thinking: "plan", payload: {})
        Samagotchi::LLM::ModelResult.new(text: "PONG", conversation: [])
      end
      events = []

      engine.run_turn(session, "hi", on_event: ->(event) { events << event })

      chunk = events.find { |event| event[:type] == :generation_chunk }
      expect(chunk).to include(text: "PONG", thinking: "plan", content: "planPONG")
    end
  end
end
