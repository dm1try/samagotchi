# frozen_string_literal: true

require "samagotchi/tool_row_fields"

RSpec.describe Samagotchi::ToolRowFields do
  it "builds a call's title, called_as, view and ref, leaving out the ones it has none of" do
    call = { name: "execute", content: "cd /x && ls -la", called_as: "bash" }
    fields = described_class.for("execute", call, cwd: "/x")
    expect(fields.keys).to eq(%i[title called_as view])
    expect(fields).to include(title: "ls -la", called_as: "bash")
    expect(fields[:view]).to include(command: "cd /x && ls -la")

    expect(described_class.for("read", { name: "read", content: "lib/a.rb", start_line: 3 }, cwd: "/x"))
      .to eq(title: "lib/a.rb", ref: { kind: "file", path: "/x/lib/a.rb", line: 3 })
  end

  it "lists every key once, in one of its two places" do
    expect(described_class::KEYS).to eq(described_class::ACTIVITY_KEYS + described_class::EVENT_KEYS)
    expect(described_class::ACTIVITY_KEYS & described_class::EVENT_KEYS).to be_empty
  end
end
