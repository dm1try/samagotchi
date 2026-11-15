# frozen_string_literal: true

require "samagotchi/task_transcript"

RSpec.describe Samagotchi::TaskTranscript do
  describe ".created_ids_in" do
    it "reads task_create results when another tool output contains invalid UTF-8" do
      content = "[task_create]\ntask_id: task-1\n\n---\n\n[execute]\n".b + "\xFF".b
      content.force_encoding(Encoding::UTF_8)

      expect(described_class.created_ids_in([{ role: "tool_response", content: content }])).to eq(["task-1"])
    end
  end

  describe ".created_id" do
    it "reads task_create ids before invalid UTF-8 in the output" do
      text = "task_id: task-1\n\xFF".b.force_encoding(Encoding::UTF_8)

      expect(described_class.created_id("task_create", text)).to eq("task-1")
    end
  end
end
