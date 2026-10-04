# frozen_string_literal: true

require "samagotchi/tool_call_parser"
require "samagotchi/model_profile"
require "samagotchi/llm/native_tool_normalizer"
RSpec.describe Samagotchi::ToolCallParser do
  describe "gemma4: current_model_only in memory_write" do
    let(:profile) { Samagotchi::ModelProfile.normalize(:gemma4) }
    let(:parser) { described_class::Gemma.new(profile) }
    it "extracts current_model_only: true from gemma wire format" do
      text = "<|tool_call>call:memory_write{content:\"overlay\", name: \"test_entry\", scope: \"system\", current_model_only:true}<tool_call|>"
      calls = parser.parse(text)
      expect(calls).to have_attributes(size: 1)
      expect(calls.first[:name]).to eq("memory_write")
      expect(calls.first[:path]).to eq("test_entry")
      expect(calls.first[:scope]).to eq("system")
      expect(calls.first[:current_model_only]).to eq("true")
    end
    it "extracts current_model_only: false from gemma wire format" do
      text = "<|tool_call>call:memory_write{content:\"base\", name: \"test_entry\", scope: \"system\", current_model_only:false}<tool_call|>"
      calls = parser.parse(text)
      expect(calls.first[:current_model_only]).to eq("false")
    end
  end

  describe "send_note and list_sessions" do
    it "parses them in the Gemma format" do
      parser = described_class::Gemma.new(Samagotchi::ModelProfile.normalize(:gemma4))

      note = parser.parse("<|tool_call>call:send_note{session:<|\"|>3f2a1c<|\"|>,text:<|\"|>the API moved<|\"|>}<tool_call|>").first
      list = parser.parse("<|tool_call>call:list_sessions{cwd:<|\"|>/work/foo<|\"|>}<tool_call|>").first

      expect(note).to include(name: "send_note", content: "the API moved", session: "3f2a1c")
      expect(list).to include(name: "list_sessions", cwd: "/work/foo")
    end

    it "parses them in the Qwen format" do
      parser = described_class::Qwen.new(Samagotchi::ModelProfile.normalize(:qwen36))

      note = parser.parse("<tool_call>\n<function=send_note>\n<parameter=session>\n3f2a1c\n</parameter>\n" \
                          "<parameter=text>\nthe API moved\n</parameter>\n</function>\n</tool_call>").first
      list = parser.parse("<tool_call>\n<function=list_sessions>\n</function>\n</tool_call>").first

      expect(note).to include(name: "send_note", content: "the API moved", session: "3f2a1c")
      expect(list).to include(name: "list_sessions")
      expect(list[:cwd].to_s).to eq("")
    end
  end

  describe "execute's cwd" do
    it "keeps it in the Gemma format" do
      parser = described_class::Gemma.new(Samagotchi::ModelProfile.normalize(:gemma4))

      call = parser.parse("<|tool_call>call:execute{command:<|\"|>ls<|\"|>,cwd:<|\"|>web<|\"|>}<tool_call|>").first
      bare = parser.parse("<|tool_call>call:execute{command:<|\"|>ls<|\"|>}<tool_call|>").first

      expect(call).to include(name: "execute", content: "ls", cwd: "web")
      expect(bare[:cwd]).to be_nil
    end

    it "keeps it in the Qwen format" do
      parser = described_class::Qwen.new(Samagotchi::ModelProfile.normalize(:qwen36))

      call = parser.parse("<tool_call>\n<function=execute>\n<parameter=command>\nls\n</parameter>\n" \
                          "<parameter=cwd>\nweb\n</parameter>\n</function>\n</tool_call>").first

      expect(call).to include(name: "execute", content: "ls", cwd: "web")
    end
  end

  describe "delegate and delegate_result" do
    it "parses them in the Gemma format, optional params left nil" do
      parser = described_class::Gemma.new(Samagotchi::ModelProfile.normalize(:gemma4))

      full = parser.parse("<|tool_call>call:delegate{task:<|\"|>count the specs<|\"|>,model:<|\"|>tiny<|\"|>,wait:false,timeout:30}<tool_call|>").first
      bare = parser.parse("<|tool_call>call:delegate{task:<|\"|>count the specs<|\"|>}<tool_call|>").first
      result = parser.parse("<|tool_call>call:delegate_result{session:<|\"|>3f2a1c<|\"|>}<tool_call|>").first

      expect(full).to include(name: "delegate", content: "count the specs", model: "tiny", session: nil)
      expect(full[:wait].to_s).to eq("false")
      expect(full[:timeout].to_s).to eq("30")
      expect(bare).to include(name: "delegate", content: "count the specs", model: nil, session: nil, wait: nil, timeout: nil)
      expect(result).to include(name: "delegate_result", session: "3f2a1c", timeout: nil)
    end

    it "parses them in the Qwen format" do
      parser = described_class::Qwen.new(Samagotchi::ModelProfile.normalize(:qwen36))

      call = parser.parse("<tool_call>\n<function=delegate>\n<parameter=task>\ncount the specs\n</parameter>\n" \
                          "<parameter=session>\n3f2a1c\n</parameter>\n<parameter=wait>\nfalse\n</parameter>\n</function>\n</tool_call>").first
      result = parser.parse("<tool_call>\n<function=delegate_result>\n</function>\n</tool_call>").first

      expect(call).to include(name: "delegate", content: "count the specs", session: "3f2a1c", wait: "false")
      expect(call[:model].to_s).to eq("")
      expect(result).to include(name: "delegate_result")
      expect(result[:session].to_s).to eq("")
    end
  end

  describe "a tool that is not a built-in (a plugin's): its arguments on args:" do
    it "Gemma: a Hash of the native values, nested ones included; built-ins get none" do
      parser = described_class::Gemma.new(Samagotchi::ModelProfile.normalize(:gemma4))
      call = parser.parse('<|tool_call>call:save_note{path:<|"|>n.md<|"|>,meta:{tags:[<|"|>a<|"|>],priority:2}}<tool_call|>').first
      expect(call).to include(name: "save_note", args: { "path" => "n.md", "meta" => { "tags" => ["a"], "priority" => 2 } })
      expect(parser.parse('<|tool_call>call:read{path:<|"|>x<|"|>}<tool_call|>').first).not_to have_key(:args)
    end

    it "Gemma: a name with digits" do
      parser = described_class::Gemma.new(Samagotchi::ModelProfile.normalize(:gemma4))
      call = parser.parse('<|tool_call>call:mcp_s3_get2{key:<|"|>k<|"|>}<tool_call|>').first
      expect(call).to include(name: "mcp_s3_get2", args: { "key" => "k" })
      expect(parser.parse("<|tool_call>call:2fast{}<tool_call|>")).to be_empty
    end

    it "Gemma: the flat scan when the body doesn't parse" do
      parser = described_class::Gemma.new(Samagotchi::ModelProfile.normalize(:gemma4))
      call = parser.parse('<|tool_call>call:save_note{path:"n.md" text:"hi"}<tool_call|>').first
      expect(call[:args]).to eq("path" => "n.md", "text" => "hi")
    end

    it "Qwen: the <parameter=…> text as given" do
      parser = described_class::Qwen.new(Samagotchi::ModelProfile.normalize(:qwen36))
      call = parser.parse("<tool_call>\n<function=save_note>\n<parameter=path>\nn.md\n</parameter>\n" \
                          "<parameter=meta>\n{\"priority\": 2}\n</parameter>\n</function>\n</tool_call>").first
      expect(call).to include(name: "save_note", args: { "path" => "n.md", "meta" => '{"priority": 2}' })
    end

    # Was Hash#inspect for Qwen ({"a"=>"1"} on Ruby 3.3, {"a" => "1"} on 3.4),
    # the body text for Gemma and the values joined for native calls.
    it "content: the arguments as JSON, the same in every format and Ruby version" do
      json = '{"path":"n.md","priority":2}'
      gemma = described_class::Gemma.new(Samagotchi::ModelProfile.normalize(:gemma4))
      qwen = described_class::Qwen.new(Samagotchi::ModelProfile.normalize(:qwen36))
      native = Samagotchi::LLM::NativeToolNormalizer.normalize(
        Struct.new(:name, :arguments).new("save_note", { "path" => "n.md", "priority" => 2 })
      )

      expect(gemma.parse('<|tool_call>call:save_note{path:<|"|>n.md<|"|>,priority:2}<tool_call|>').first[:content]).to eq(json)
      expect(qwen.parse("<tool_call>\n<function=save_note>\n<parameter=path>\nn.md\n</parameter>\n" \
                        "<parameter=priority>\n2\n</parameter>\n</function>\n</tool_call>").first[:content])
        .to eq('{"path":"n.md","priority":"2"}')
      expect(native[:content]).to eq(json)
    end
  end

  describe "Qwen#strip_thought" do
    let(:parser) { described_class::Qwen.new(Samagotchi::ModelProfile.normalize(:qwen36)) }

    # A chat host's answer has no think block at all, and it is saved as
    # stripped: collapsing every blank line merged its markdown paragraphs
    # and lists for good.
    it "keeps the blank lines of an answer with no think block" do
      answer = "All checks passed:\n\n- a\n- b\n\nAll **good**.\n\n\nSecond paragraph."
      expect(parser.strip_thought(answer)).to eq(answer)
    end

    it "drops a block with the blank lines after it and keeps the answer's own" do
      expect(parser.strip_thought("<think>\nplan\n</think>\n\nOne.\n\nTwo.")).to eq("One.\n\nTwo.")
      expect(parser.strip_thought("</think>\n\nOne.\n\nTwo.")).to eq("One.\n\nTwo.")
    end
  end
end
