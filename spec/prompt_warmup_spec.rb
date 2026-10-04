# frozen_string_literal: true

require "samagotchi/prompt_warmup"
require "samagotchi/kernel_loop"
require "samagotchi/model_profile"

RSpec.describe Samagotchi::PromptWarmup do
  subject(:warmup) { described_class.new }

  let(:client) { instance_double(Samagotchi::Client) }
  let(:gate) { Queue.new }

  def start_held(slot: 1)
    allow(client).to receive(:warm_up) do
      gate.pop
      Samagotchi::Client::Warmup.new(slot: slot, cache_n: 10, prompt_n: 5, prompt_ms: 7)
    end
    warmup.start(client: client, prompt: "head", model: "m", slot: slot)
  end

  describe "#take_pin" do
    it "pins the next request to the warm-up's slot while it still runs, then never again" do
      start_held(slot: 2)

      expect(warmup.take_pin(client)).to eq(2)
      expect(warmup.take_pin(client)).to be_nil
      gate << :go
      warmup.wait(2)
    end

    it "pins nothing once the warm-up is done: the server finds the state itself" do
      start_held(slot: 2)
      gate << :go
      warmup.wait(2)

      expect(warmup.take_pin(client)).to be_nil
    end

    it "pins nothing for another host's client, and forgets the warm-up" do
      start_held(slot: 2)
      other = instance_double(Samagotchi::Client)

      expect(warmup.take_pin(other)).to be_nil
      expect(warmup.take_pin(client)).to be_nil
      gate << :go
      warmup.wait(2)
    end

    it "pins nothing for a warm-up sent without a slot" do
      start_held(slot: nil)

      expect(warmup.take_pin(client)).to be_nil
      gate << :go
      warmup.wait(2)
    end

    it "pins nothing when no warm-up ran" do
      expect(warmup.take_pin(client)).to be_nil
    end
  end

  it "logs a failed warm-up and never raises" do
    allow(client).to receive(:warm_up).and_raise(Errno::ECONNREFUSED)
    allow(Samagotchi::Log).to receive(:warn)

    warmup.start(client: client, prompt: "head", model: "m", slot: 0)
    warmup.wait(2)

    expect(Samagotchi::Log).to have_received(:warn).with(:model, "warmup_failed", hash_including(error: "Errno::ECONNREFUSED"))
  end

  describe ".enabled?" do
    it "is on by default (auto) and off for off, false, no or 0" do
      expect(with_env("SAMAGOTCHI_CACHE_WARMUP" => nil) { described_class.enabled? }).to be(true)
      expect(with_env("SAMAGOTCHI_CACHE_WARMUP" => "auto") { described_class.enabled? }).to be(true)
      %w[off OFF false no 0].each do |value|
        expect(with_env("SAMAGOTCHI_CACHE_WARMUP" => value) { described_class.enabled? }).to be(false)
      end
    end
  end
end

RSpec.describe Samagotchi::KernelLoop, "turn-end warm-up" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:requests) { [] }

  def kernel_for(profile)
    described_class.new(client: client, profile: profile)
  end

  def script(*responses, slot: nil)
    allow(client).to receive(:complete) do |prompt, on_chunk: nil, **kwargs|
      requests << kwargs.merge(prompt: prompt)
      text = responses.length > 1 ? responses.shift : responses.first
      payload = { "content" => text }
      payload["id_slot"] = slot if slot
      on_chunk&.call(content: text, payload: payload)
      text
    end
  end

  [Samagotchi::ModelProfile.qwen36, Samagotchi::ModelProfile.gemma4].each do |profile|
    it "formats the next turn's prompt up to its user message (#{profile.name})" do
      kernel = kernel_for(profile)
      script("Hello there")
      first = kernel.run([{ role: "system", content: "base" }, { role: "user", content: "hi" }])

      warm, images = kernel.warmup_prompt(first.conversation)
      kernel.run(first.conversation + [{ role: "user", content: "next" }])
      next_prompt = requests.last[:prompt]

      expect(images).to eq([])
      expect(next_prompt).to start_with(warm)
      opener = profile.uses_role_prefixes? ? profile.user_prefix : "#{profile.turn_start}user\n"
      expect(next_prompt.delete_prefix(warm)).to start_with("#{opener}next")
    end
  end

  it "strips the last answer's thinking, as the next turn does" do
    kernel = kernel_for(Samagotchi::ModelProfile.qwen36)
    script("<think>\nponder\n</think>\n\nAnswer")
    first = kernel.run([{ role: "system", content: "base" }, { role: "user", content: "hi" }])

    warm, = kernel.warmup_prompt(first.conversation)

    expect(warm).not_to include("ponder")
    expect(warm).to end_with("Answer<|im_end|>\n")
  end

  it "remembers the slot the last request streamed from" do
    kernel = kernel_for(Samagotchi::ModelProfile.qwen36)
    script("ok", slot: 3)

    kernel.run([{ role: "user", content: "hi" }])

    expect(kernel.last_slot).to eq(3)
  end

  it "pins only the first request of a turn, to the slot the warm-up pins" do
    kernel = kernel_for(Samagotchi::ModelProfile.qwen36)
    warmup = instance_double(Samagotchi::PromptWarmup)
    allow(warmup).to receive(:take_pin).with(client).and_return(1, nil)
    kernel.warmup = warmup
    tool_call = "<tool_call>\n<function=read>\n<parameter=path>\nnope.txt\n</parameter>\n</function>\n</tool_call>"
    script(tool_call, "done")

    kernel.run([{ role: "user", content: "hi" }])

    expect(requests.map { |request| request[:slot] }).to eq([1, nil])
  end
end
