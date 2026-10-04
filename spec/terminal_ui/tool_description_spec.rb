# frozen_string_literal: true

require "samagotchi/terminal_ui"
require_relative "../support/recording_surface"

# A command's description (execute's optional few words) in place of its
# cut params on the tool line; the params stay as they are everywhere else.
RSpec.describe "TerminalUI command descriptions" do
  def view
    Class.new do
      include Samagotchi::TerminalUI::Formatting

      def color_output? = false
    end.new
  end

  it "shows the description in place of the params, the params without one" do
    activity = { action: "running command", tool: "execute", params: 'command="ls"', status: "ok" }
    expect(view.format_tool_activity_line(activity.merge(description: "List files")))
      .to eq("tool> running command (execute: List files): ok")
    expect(view.format_tool_activity_line(activity.merge(description: " "))).to eq('tool> running command (execute command="ls"): ok')
    expect(view.snapshot_tool_line({ tool: "execute", params: 'command="ls"', status: "ok", description: "List files" }))
      .to eq("tool> execute: List files: ok")
  end

  it "takes a replayed completion's description from its view" do
    surface = RecordingSurface.new(columns: 120)
    attached_view = Samagotchi::TerminalUI::AttachedView.new(surface)
    allow(attached_view).to receive(:color_output?).and_return(false)
    renderer = Samagotchi::TerminalUI::EventRenderer.new(attached_view)
    renderer.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "execute", params: 'command="ls"',
                  view: { command: "ls", description: "List files." })
    renderer.call(type: :tool_call_completed, iteration: 1, call_index: 1, tool: "execute", duration_ms: nil,
                  activity: { action: "running command", tool: "execute", params: 'command="ls"', status: "ok" },
                  view: { "command" => "ls", "description" => "List files." })

    expect(surface.lines).to include("tool> running command (execute: List files): ok")
  end
end
