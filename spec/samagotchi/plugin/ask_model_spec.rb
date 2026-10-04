# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plugin/context"
require "samagotchi/plugin/side_question"

# ctx.ask_model (plan D7): one tool-less request about the conversation.
RSpec.describe "ctx.ask_model" do
  let(:asked) { [] }
  let(:answer) { "a side answer" }
  let(:host) do
    Samagotchi::Plugin::Host.new(
      session_id: -> { "s1" }, cwd: -> { Dir.pwd }, messages: -> { [] },
      ask_model: lambda { |request, **options|
        asked << [request, options]
        answer.respond_to?(:call) ? answer.call : answer
      }
    )
  end
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "b", label: "plugin.rb (bundle b)", settings: {}, host: host) }

  let(:conversation) do
    [
      { role: "system", content: "You are chi. (the system prompt)" },
      { role: "user", content: "Rename foo to bar", images: [{ file: "images/0123456789abcdef.png", name: "shot.png" }] },
      { role: "model", content: "<|think|>hmm|think|>Looking.<|tool_call>call:read{path:foo}<tool_call|>" },
      { role: "tool_response", content: "[read]\nSECRET FILE BODY" },
      { role: "model", content: "Renamed it." }
    ]
  end

  it "sends the transcript and the question, without the system prompt, tool output or thinking" do
    expect(ctx.ask_model(messages: conversation, prompt: "what did we rename?")).to eq("a side answer")

    request, options = asked.first
    expect(request.first).to eq(role: "system", content: Samagotchi::Plugin::SideQuestion::DEFAULT_SYSTEM)
    user = request.last[:content]
    expect(user).to eq("<conversation>\nUser: Rename foo to bar\n[image shot.png]\n\nAssistant: Looking.\n\n" \
                       "Assistant: Renamed it.\n</conversation>\n\nwhat did we rename?")
    expect(user).not_to include("SECRET", "chi. (the system prompt)", "hmm", "call:read")
    expect(options).to eq(timeout: 120.0, max_tokens: Samagotchi::Plugin::Context::ASK_MAX_TOKENS, cancel_controller: nil)
  end

  it "takes its own system text, limit, timeout and cancel controller" do
    controller = Object.new
    ctx.ask_model(messages: [], prompt: "q", system: "be terse", timeout: 5, max_tokens: 50, cancel: controller)

    request, options = asked.first
    expect(request).to eq([{ role: "system", content: "be terse" }, { role: "user", content: "q" }])
    expect(options).to eq(timeout: 5.0, max_tokens: 50, cancel_controller: controller)
  end

  it "keeps the tail of a long conversation" do
    long = Array.new(40) { |i| { role: "user", content: "#{i} #{"x" * 1_000}" } }
    user = Samagotchi::Plugin::SideQuestion.request(messages: long, prompt: "q").last[:content]

    expect(user).to include("[earlier conversation left out]", "User: 39 ")
    expect(user).not_to include("User: 0 ")
  end

  it "needs a prompt" do
    expect { ctx.ask_model(messages: [], prompt: " ") }.to raise_error(ArgumentError, /prompt/)
    expect(asked).to be_empty
  end

  it "raises ModelError when the request fails, ModelCancelled when cancelled" do
    failing = Samagotchi::Plugin::Host.new(ask_model: ->(*) { raise Samagotchi::IdleClient::SummarizeError, "server down" })
    cancelled = Samagotchi::Plugin::Host.new(ask_model: ->(*) { raise Samagotchi::LLM::RequestCancelled, :manual })
    build = ->(h) { Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: h) }

    expect { build.call(failing).ask_model(messages: [], prompt: "q") }.to raise_error(Samagotchi::Plugin::ModelError, "server down")
    expect { build.call(cancelled).ask_model(messages: [], prompt: "q") }.to raise_error(Samagotchi::Plugin::ModelCancelled)
  end
end
