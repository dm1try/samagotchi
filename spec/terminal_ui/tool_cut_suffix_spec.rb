# frozen_string_literal: true

require "samagotchi/terminal_ui"
require_relative "../support/recording_surface"

# A tool output longer than max_tool_output_chars is cut (the model gets the
# "[cut: N of M chars...]" note): its row says so, as the web's does.
RSpec.describe "TerminalUI cut tool rows" do
  def view(color:)
    Class.new do
      include Samagotchi::TerminalUI::Formatting

      def initialize(color) = @color = color
      def color_output? = @color
    end.new(color)
  end

  it "formats a dim [cut] only for a truncated output" do
    expect(view(color: false).format_tool_cut_suffix(true)).to eq(" [cut]")
    expect(view(color: false).format_tool_cut_suffix(false)).to eq("")
    expect(view(color: false).format_tool_cut_suffix(nil)).to eq("")
    expect(view(color: true).format_tool_cut_suffix(true)).to eq(" \e[90m[cut]\e[0m")
  end

  it "puts it after the live completed row's line through the EventRenderer" do
    surface = RecordingSurface.new(columns: 80)
    attached_view = Samagotchi::TerminalUI::AttachedView.new(surface)
    allow(attached_view).to receive(:color_output?).and_return(false)
    renderer = Samagotchi::TerminalUI::EventRenderer.new(attached_view)
    renderer.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "read")
    renderer.call(type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", output_truncated: true,
                  activity: { action: "reading file", tool: "read", params: "path=big", status: "ok" })
    renderer.call(type: :tool_call_started, iteration: 1, call_index: 2, tool: "read")
    renderer.call(type: :tool_call_completed, iteration: 1, call_index: 2, tool: "read", output_truncated: false,
                  activity: { action: "reading file", tool: "read", params: "path=small", status: "ok" })

    expect(surface.lines).to include(a_string_matching(/\Atool> reading file \(read path=big\): ok.* \[cut\]\z/),
                                     a_string_matching(/\Atool> reading file \(read path=small\): ok(?!.*\[cut\]).*\z/))
  end
end
