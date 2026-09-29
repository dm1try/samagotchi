# frozen_string_literal: true

require "samagotchi/terminal_ui"
require_relative "../support/recording_surface"

# An edit/write row's " +3 −1" (the diff itself is on the web).
RSpec.describe "TerminalUI edit rows" do
  def view(color:)
    Class.new do
      include Samagotchi::TerminalUI::Formatting

      def initialize(color) = @color = color
      def color_output? = @color
    end.new(color)
  end

  it "formats +added −removed, green and red, from symbol or string keys" do
    expect(view(color: false).format_tool_diff_suffix({ added: 3, removed: 1 })).to eq(" +3 \u22121")
    expect(view(color: false).format_tool_diff_suffix({ "added" => 2, "removed" => 0 })).to eq(" +2 \u22120")
    expect(view(color: true).format_tool_diff_suffix({ added: 3, removed: 1 })).to eq(" \e[32m+3\e[0m \e[31m\u22121\e[0m")
    expect(view(color: false).format_tool_diff_suffix(nil)).to eq("")
  end

  it "puts it after the completed row's line through the EventRenderer" do
    surface = RecordingSurface.new(columns: 80)
    attached_view = Samagotchi::TerminalUI::AttachedView.new(surface)
    allow(attached_view).to receive(:color_output?).and_return(false)
    renderer = Samagotchi::TerminalUI::EventRenderer.new(attached_view)
    renderer.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "edit")
    renderer.call(type: :tool_call_completed, iteration: 1, call_index: 1, tool: "edit", diff: { "added" => 1, "removed" => 1 },
                  activity: { action: "editing file", tool: "edit", params: "path=k.conf", status: "ok" })
    renderer.call(type: :tool_call_started, iteration: 1, call_index: 2, tool: "read")
    renderer.call(type: :tool_call_completed, iteration: 1, call_index: 2, tool: "read",
                  activity: { action: "reading file", tool: "read", params: "path=k.conf", status: "ok" })

    expect(surface.lines).to include(a_string_matching(/\Atool> editing file \(edit path=k.conf\): ok.* \+1 \u22121\z/),
                                     a_string_matching(/\Atool> reading file \(read path=k.conf\): ok[^+]*\z/))
  end
end
