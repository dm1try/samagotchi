# frozen_string_literal: true

require "samagotchi/thinking_notices"
require "samagotchi/host_registry"

# The notices' own failures (spec/engine_thinking_notice_spec.rb has what
# they say): one that fails says nothing and the turn goes on, with a log
# line once per process.
RSpec.describe Samagotchi::ThinkingNotices do
  let(:registry) { Samagotchi::HostRegistry.new(hosts_config: { "box" => { host: "box.test", port: 8080 } }) }
  let(:target) { registry.resolve("box:qwen-small") }
  let(:profile) { Samagotchi::ModelProfile.named("qwen36") }
  let(:said) { [] }
  let(:lines) { [] }

  before do
    %i[warn debug].each do |level|
      allow(Samagotchi::Log).to receive(level).and_wrap_original do |original, tag, event, **fields|
        lines << [level, event, fields[:error]] if event == "thinking_notice_failed"
        original.call(tag, event, **fields)
      end
    end
  end

  def notices(notify) = described_class.new(session: -> {}, profile: -> { profile }, notify: notify)

  it "says an effort native Qwen can't do once, keeping the turn's level and model" do
    subject = notices(->(text, level, source) { said << [text, level, source] })
    2.times { subject.turn_started(:low, target) }

    expect(subject.turn).to eq([:low, target])
    expect(said).to eq([["low isn't supported by native qwen36 on box; thinking stays as the model has it", :info, "thinking"]])
  end

  it "logs a notice that fails, warning once, and raises nothing" do
    subject = notices(->(*) { raise IOError, "sink gone" })

    subject.turn_started(:low, target)
    subject.thinking_refused(level: :off, model: "qwen-small", detail: "no")

    expect(lines).to eq([[:warn, "thinking_notice_failed", "IOError"], [:debug, "thinking_notice_failed", "IOError"]])
  end
end
