# frozen_string_literal: true

require "spec_helper"
require "samagotchi/terminal_ui"

RSpec.describe Samagotchi::TerminalUI do
  describe "#process_background_prompt" do
    before { allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil) }

    it "uses KernelLoop#run and returns model output" do
      kernel = instance_double(Samagotchi::KernelLoop)
      allow(Samagotchi::KernelLoop).to receive(:new).and_return(kernel)
      allow(kernel).to receive(:use_profile!)

      conversation = [
        { role: "user", content: "hello" },
        { role: "model", content: "pong" }
      ]
      result = Samagotchi::KernelLoop::Result.new(
        output: "pong",
        conversation: conversation,
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: []
      )
      expect(kernel).to receive(:run) do |messages|
        expect(messages.first[:role]).to eq("system")
        expect(messages.last).to eq({ role: "user", content: "hello" })
        result
      end

      agent = described_class.new(mode: "assist", model_name: "gemma4")
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd)

      response = agent.process_background_prompt(session: session, prompt: "hello")

      expect(response).to eq("pong")
      expect(session.messages).to eq(conversation)
      expect(session.last_prompt).to eq("hello")
    end

    it "returns no-response fallback when kernel output is blank" do
      kernel = instance_double(Samagotchi::KernelLoop)
      allow(Samagotchi::KernelLoop).to receive(:new).and_return(kernel)
      allow(kernel).to receive(:use_profile!)

      result = Samagotchi::KernelLoop::Result.new(
        output: "",
        conversation: [{ role: "user", content: "hello" }],
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: []
      )
      allow(kernel).to receive(:run).and_return(result)

      agent = described_class.new(mode: "assist", model_name: "gemma4")
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd)

      response = agent.process_background_prompt(session: session, prompt: "hello")

      expect(response).to eq("[No response]")
      expect(session.messages.last).to eq({ role: "model", content: "[No response]" })
    end
  end
end
