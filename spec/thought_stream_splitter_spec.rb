# frozen_string_literal: true

require "samagotchi/thought_stream_splitter"
require "samagotchi/model_profile"

RSpec.describe Samagotchi::ThoughtStreamSplitter do
  QWEN = Samagotchi::ModelProfile.qwen36
  GEMMA = Samagotchi::ModelProfile.gemma4

  # Derive markers from the profile so the literal token strings are never
  # spelled out inline (keeps the spec byte-stable and profile-truthful).
  THINK_OPEN = QWEN.thought_open
  THINK_CLOSE = QWEN.thought_close
  TC_OPEN = QWEN.tool_call_open
  TC_CLOSE = QWEN.tool_call_close

  def run_chunks(splitter, chunks)
    text = +""
    thinking = +""
    chunks.each do |chunk|
      d = splitter.feed(chunk)
      text << d[:text]
      thinking << d[:thinking]
    end
    d = splitter.finalize
    text << d[:text]
    thinking << d[:thinking]
    { text: text, thinking: thinking }
  end

  describe ".for_profile" do
    it "registers thinking + tool_call blocks for a profile with an explicit think close (Qwen)" do
      splitter = described_class.for_profile(QWEN)
      expect(splitter.feed(THINK_OPEN)[:thinking]).to eq("")
      expect(splitter.feed("x")[:thinking]).to eq("x")
    end

    it "keeps Gemma's bare think cue in :text (it has no close) and drops its tool_call bodies" do
      expect(GEMMA.thought_close).to be_nil
      splitter = described_class.for_profile(GEMMA)
      expect(splitter.feed(GEMMA.thought_open)[:text]).to eq(GEMMA.thought_open)
      # Gemma tool_call markers are dropped.
      out = run_chunks(described_class.for_profile(GEMMA), [GEMMA.tool_call_open, "body", GEMMA.tool_call_close])
      expect(out[:text]).to eq("")
      expect(out[:thinking]).to eq("")
    end

    it "splits Gemma's thought channel into :thinking, markers dropped, across chunk boundaries" do
      chunks = ["<|chan", "nel>thought\nweighing ", "options<chan", "nel|>Hi ", "there."]
      out = run_chunks(described_class.for_profile(GEMMA), chunks)
      expect(out[:thinking]).to eq("\nweighing options")
      expect(out[:text]).to eq("Hi there.")
    end

    it "registers no thought channel for Qwen" do
      out = run_chunks(described_class.for_profile(QWEN), ["<|channel>thought x<channel|>y"])
      expect(out[:text]).to eq("<|channel>thought x<channel|>y")
    end
  end

  describe "#feed (Qwen, single chunk)" do
    it "routes a thinking block to :thinking and surrounding prose to :text" do
      out = run_chunks(described_class.for_profile(QWEN), ["hi #{THINK_OPEN}reasoning#{THINK_CLOSE}there"])
      expect(out[:text]).to eq("hi there")
      expect(out[:thinking]).to eq("reasoning")
    end

    it "drops tool_call block bodies from :text" do
      out = run_chunks(described_class.for_profile(QWEN), ["a #{TC_OPEN}<function>x</function>#{TC_CLOSE}b"])
      expect(out[:text]).to eq("a b")
      expect(out[:thinking]).to eq("")
    end

    it "handles thinking and tool_call in one stream" do
      stream = "start #{THINK_OPEN}think1#{THINK_CLOSE} mid #{TC_OPEN}call#{TC_CLOSE} end"
      out = run_chunks(described_class.for_profile(QWEN), [stream])
      expect(out[:text]).to eq("start  mid  end")
      expect(out[:thinking]).to eq("think1")
    end

    it "returns empty lanes for plain prose" do
      out = run_chunks(described_class.for_profile(QWEN), ["just prose"])
      expect(out[:text]).to eq("just prose")
      expect(out[:thinking]).to eq("")
    end
  end

  describe "#feed (Qwen, markers split across chunks)" do
    it "re-assembles a thinking open marker split across chunks" do
      splitter = described_class.for_profile(QWEN)
      half = THINK_OPEN.length / 2
      a = splitter.feed("hi #{THINK_OPEN[0, half]}")
      b = splitter.feed(THINK_OPEN[half..] + "reason#{THINK_CLOSE}")
      c = splitter.feed("yo")
      d = splitter.finalize
      text = a[:text] + b[:text] + c[:text] + d[:text]
      thinking = a[:thinking] + b[:thinking] + c[:thinking] + d[:thinking]
      expect(text).to eq("hi yo")
      expect(thinking).to eq("reason")
    end

    it "re-assembles a thinking close marker split across chunks" do
      splitter = described_class.for_profile(QWEN)
      half = THINK_CLOSE.length / 2
      a = splitter.feed("hi #{THINK_OPEN}reason#{THINK_CLOSE[0, half]}")
      b = splitter.feed(THINK_CLOSE[half..] + "yo")
      d = splitter.finalize
      text = a[:text] + b[:text] + d[:text]
      thinking = a[:thinking] + b[:thinking] + d[:thinking]
      expect(text).to eq("hi yo")
      expect(thinking).to eq("reason")
    end

    it "re-assembles a tool_call close marker split across chunks" do
      splitter = described_class.for_profile(QWEN)
      half = TC_CLOSE.length / 2
      a = splitter.feed("a #{TC_OPEN}<function>f</function>#{TC_CLOSE[0, half]}")
      b = splitter.feed(TC_CLOSE[half..] + "b")
      d = splitter.finalize
      text = a[:text] + b[:text] + d[:text]
      expect(text).to eq("a b")
    end
  end

  describe "#feed (edge cases)" do
    it "treats a leading partial open marker as carry, not text" do
      splitter = described_class.for_profile(QWEN)
      a = splitter.feed(THINK_OPEN[0, 1])
      expect(a[:text]).to eq("")
      expect(a[:thinking]).to eq("")
    end

    it "finalizes an unterminated thinking block as thinking" do
      splitter = described_class.for_profile(QWEN)
      a = splitter.feed("hi #{THINK_OPEN}unterminated")
      d = splitter.finalize
      text = a[:text] + d[:text]
      thinking = a[:thinking] + d[:thinking]
      expect(text).to eq("hi ")
      expect(thinking).to eq("unterminated")
    end

    it "finalizes an unterminated tool_call block by dropping its body" do
      splitter = described_class.for_profile(QWEN)
      a = splitter.feed("a #{TC_OPEN}dropped")
      d = splitter.finalize
      text = a[:text] + d[:text]
      expect(text).to eq("a ")
    end

    it "emits empty deltas for an empty chunk" do
      splitter = described_class.for_profile(QWEN)
      expect(splitter.feed("")).to eq(text: "", thinking: "", tool: false)
    end

    it "handles a thinking block with empty body" do
      out = run_chunks(described_class.for_profile(QWEN), ["x #{THINK_OPEN}#{THINK_CLOSE} y"])
      expect(out[:text]).to eq("x  y")
      expect(out[:thinking]).to eq("")
    end

    it "accumulates thinking across multiple thinking blocks in one turn" do
      out = run_chunks(
        described_class.for_profile(QWEN),
        ["a #{THINK_OPEN}t1#{THINK_CLOSE} b #{THINK_OPEN}t2#{THINK_CLOSE} c"]
      )
      expect(out[:text]).to eq("a  b  c")
      expect(out[:thinking]).to eq("t1t2")
    end
  end

  describe "feed returns deltas (not cumulative)" do
    it "only reports newly routed bytes per chunk" do
      splitter = described_class.for_profile(QWEN)
      a = splitter.feed("hello ")
      b = splitter.feed("world")
      expect(a[:text]).to eq("hello ")
      expect(b[:text]).to eq("world")
    end
  end

  # The tool-call lane: a steer must not cut a generation that streams a
  # tool call (Engine#cut_for_steer), so #feed says when a chunk touched one.
  describe "#feed tool:" do
    [["Qwen", QWEN], ["Gemma", GEMMA]].each do |name, profile|
      it "is true for a chunk that opens a tool call, even with no body yet (#{name})" do
        splitter = described_class.for_profile(profile)
        expect(splitter.feed("ok #{profile.tool_call_open}")[:tool]).to be(true)
      end

      it "is true for a chunk inside a tool call and for the one that closes it (#{name})" do
        splitter = described_class.for_profile(profile)
        splitter.feed(profile.tool_call_open)
        expect(splitter.feed("call:write{")[:tool]).to be(true)
        expect(splitter.feed("}#{profile.tool_call_close}")[:tool]).to be(true)
        expect(splitter.feed(" after")[:tool]).to be(false)
      end

      it "is false for thinking and text (#{name})" do
        splitter = described_class.for_profile(profile)
        open = profile.thought_channel_open || profile.thought_open
        expect(splitter.feed("#{open}weighing")[:tool]).to be(false)
        expect(splitter.feed("more")[:tool]).to be(false)
        expect(splitter.feed("plain text")[:tool]).to be(false)
      end
    end

    it "sets once a tool-call open marker split across chunks completes" do
      splitter = described_class.for_profile(QWEN)
      half = TC_OPEN.length / 2
      expect(splitter.feed("x #{TC_OPEN[0, half]}")[:tool]).to be(false)
      expect(splitter.feed(TC_OPEN[half..])[:tool]).to be(true)
    end
  end
end
