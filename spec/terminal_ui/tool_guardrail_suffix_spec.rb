# frozen_string_literal: true

require "samagotchi/terminal_ui"
require_relative "../support/recording_surface"

# A call System 1 allowed once instead of asking says so on its row (the web's
# "auto-allowed · System 1" label); any other guardrail data changes nothing.
RSpec.describe "TerminalUI System 1 tool rows" do
  let(:system_one) do
    { rule: "git-push", verdict: "allow", decided_by: "system one", scope: "once",
      note: "auto-allowed by System 1 (p=0.97)", judgment_id: "j1", p: 0.97 }
  end

  def view(color:)
    Class.new do
      include Samagotchi::TerminalUI::Formatting

      def initialize(color) = @color = color
      def color_output? = @color
    end.new(color)
  end

  it "formats a yellow suffix only for a System 1 decision, p to two places" do
    expect(view(color: false).format_tool_guardrail_suffix(system_one)).to eq(" · auto-allowed (System 1, p=0.97)")
    expect(view(color: false).format_tool_guardrail_suffix(system_one.merge(p: 0.9))).to include("p=0.90")
    expect(view(color: true).format_tool_guardrail_suffix(system_one)).to start_with(" \e[33m")
    expect(view(color: false).format_tool_guardrail_suffix("decided_by" => "system one", "p" => 0.5)).to include("p=0.50")
    expect(view(color: false).format_tool_guardrail_suffix(system_one.merge(decided_by: "user"))).to eq("")
    expect(view(color: false).format_tool_guardrail_suffix(nil)).to eq("")
  end

  it "puts it after the live completed row's line through the EventRenderer" do
    surface = RecordingSurface.new(columns: 100)
    attached_view = Samagotchi::TerminalUI::AttachedView.new(surface)
    allow(attached_view).to receive(:color_output?).and_return(false)
    renderer = Samagotchi::TerminalUI::EventRenderer.new(attached_view)
    [[1, system_one], [2, system_one.merge(decided_by: "user")], [3, nil]].each do |index, guardrail|
      activity = { action: "running", tool: "execute", params: "command=#{index}", status: "ok" }
      activity[:guardrail] = guardrail if guardrail
      renderer.call(type: :tool_call_started, iteration: 1, call_index: index, tool: "execute")
      renderer.call(type: :tool_call_completed, iteration: 1, call_index: index, tool: "execute", activity: activity)
    end

    expect(surface.lines).to include(a_string_matching(/command=1\): ok.* · auto-allowed \(System 1, p=0\.97\)\z/))
    expect(surface.lines.grep(/command=[23]\)/)).to all(satisfy { |line| !line.include?("auto-allowed") })
  end
end
