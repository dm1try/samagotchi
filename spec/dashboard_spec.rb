
# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/dashboard"

RSpec.describe Samagotchi::Dashboard do
  describe "constants" do
    it "has correct command strings" do
      expect(described_class::QUIT_COMMAND).to eq("/quit")
      expect(described_class::DETACH_COMMAND).to eq("/detach")
      expect(described_class::STOP_COMMAND).to eq("/stop")
      expect(described_class::CONTINUE_PROMPT).to eq("/continue")
    end
  end

  describe "#initialize" do
    it "creates with empty sessions" do
      dashboard = described_class.new
      expect(dashboard.instance_variable_get(:@sessions)).to eq([])
    end
  end

  describe "#run" do
    it "handles Ctrl-C gracefully" do
      dashboard = described_class.new
      allow(dashboard).to receive(:render_menu)
      allow($stdin).to receive(:gets).and_raise(Interrupt)

      expect { dashboard.run }.to output(/Interrupted\.\nGoodbye!/).to_stdout
    end
  end

  describe "attach menu context preview" do
    it "renders recent session messages" do
      dashboard = described_class.new
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [
        { role: "system", content: "system prompt" },
        { role: "user", content: "first" },
        { role: "model", content: "second" },
        { role: "user", content: "third" },
        { role: "model", content: "fourth" }
      ]

      allow(Samagotchi::Session).to receive(:load).with(session.id).and_return(session)

      original_stdout = $stdout
      buffer = StringIO.new
      $stdout = buffer
      begin
        dashboard.send(:render_attach_menu, session)
      ensure
        $stdout = original_stdout
      end

      output = buffer.string
      expect(output).to include("Recent:")
      expect(output).to include("you> first")
      expect(output).to include("chi> second")
      expect(output).to include("you> third")
      expect(output).to include("chi> fourth")
      expect(output).not_to include("sys> system prompt")
    end

    it "shows empty state when there are no messages" do
      dashboard = described_class.new
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")

      allow(Samagotchi::Session).to receive(:load).with(session.id).and_return(session)

      original_stdout = $stdout
      buffer = StringIO.new
      $stdout = buffer
      begin
        dashboard.send(:render_attach_menu, session)
      ensure
        $stdout = original_stdout
      end

      expect(buffer.string).to include("Recent: (none yet)")
    end

    it "normalizes whitespace and truncates long previews" do
      dashboard = described_class.new
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      long = "line one\nline two\t" + ("x" * 200)
      session.messages = [{ role: "model", content: long }]

      allow(Samagotchi::Session).to receive(:load).with(session.id).and_return(session)

      original_stdout = $stdout
      buffer = StringIO.new
      $stdout = buffer
      begin
        dashboard.send(:render_attach_menu, session)
      ensure
        $stdout = original_stdout
      end

      output = buffer.string
      expect(output).to include("chi> line one line two")
      expect(output).to include("...")
    end
  end
end

