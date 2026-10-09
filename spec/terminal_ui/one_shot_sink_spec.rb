# frozen_string_literal: true

require "stringio"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/one_shot_sink"

# The turn sink of `chi -p … --non-interactive`: the lines a script's
# reader wants on stderr while stdout waits for the answer.
RSpec.describe Samagotchi::TerminalUI::OneShotSink do
  let(:err) { StringIO.new }
  let(:sink) { described_class.new(err: err) }

  it "prints the empty-answer retry line" do
    sink.call({ type: :empty_answer_retry, attempt: 1, of: 1 })
    sink.call({ type: :empty_answer_retry, attempt: 1, of: 2, stopped_by: "loop-guard" })

    expect(err.string).to eq("↻ empty answer, asking again (1/1)\n↻ cut by loop-guard, asking again (1/2)\n")
  end

  it "prints a steer's cut row" do
    sink.call({ type: :steer_cut, iteration: 1, source: "chi_send" })

    expect(err.string).to eq("↪ cut in for a message sent with chi send\n")
  end

  it "prints a batch of LLM context edits as the server's ✂ line" do
    sink.call({ type: :llm_context_edited, moment: "turn_end", text: "✂ stubbed 1 stale read · frees ~640 tokens (at turn end)" })

    expect(err.string).to eq("✂ stubbed 1 stale read · frees ~640 tokens (at turn end)\n")
  end

  it "prints the generation retry line" do
    sink.call({ type: :generation_retrying, attempt: 1, max_retries: 3, next_delay: 0.5, error_class: "Errno::ECONNREFUSED" })

    expect(err.string).to eq("↻ retrying (ECONNREFUSED) in 0.5s, 1/3\n")
  end

  it "prints a hook's notice during the turn at once, and keeps one after its end for #flush (a fallback_for one too)" do
    sink.call({ type: :hook_notice, hook: "loop-guard.rb (bundle loop-guard)", text: "looping?", level: :warn })
    sink.call({ type: :turn_completed })
    sink.call({ type: :hook_notice, hook: "sources.rb (bundle source-links)", text: "sources: JIRA-1", level: :info,
                fallback_for: :display })
    expect(err.string).to eq("loop-guard> warning: looping?\n")

    sink.flush
    sink.flush
    expect(err.string).to eq("loop-guard> warning: looping?\nsource-links> sources: JIRA-1\n")
  end

  it "prints nothing for the other events" do
    sink.call({ type: :generation_chunk, text: "hi" })
    sink.call({ type: :tool_call_started, tool: "read" })
    sink.call({ type: :turn_completed })

    expect(err.string).to eq("")
  end

  it "colours a line only on a colour terminal" do
    tty = StringIO.new
    def tty.tty? = true
    described_class.new(err: tty).call({ type: :empty_answer_retry, attempt: 1, of: 1 })

    expect(tty.string).to eq("\e[90m↻ empty answer, asking again (1/1)\e[0m\n")
  end
end
