# frozen_string_literal: true

require "json"
require "spec_helper"
require "samagotchi/tools/task_record"

RSpec.describe Samagotchi::Tools::TaskRecord, ".short_id" do
  it "is a task id's random part (task_create's ids start with the time), else its first 8 chars" do
    expect(described_class.short_id("20261019164550-0e055c67")).to eq("0e055c67")
    expect(described_class.short_id("3f9a2c1d-0000-4000-8000-000000000000")).to eq("3f9a2c1d")
    expect(described_class.short_id("t1")).to eq("t1")
  end
end

RSpec.describe Samagotchi::Tools::TaskRecord do
  let(:created) do
    described_class.running(id: "20261014120000-1a2b3c4d", command: "sleep 30", cwd: "/w", pid: 42,
                            pid_started: "Tue Oct 14 12:00:00 2026", started_at: "2026-10-14T12:00:00Z",
                            output_path: "tmp/tasks/20261014120000-1a2b3c4d/output.log",
                            exit_code_path: "tmp/tasks/20261014120000-1a2b3c4d/exit_code")
  end

  it "writes a task_create record's task.json keys in their order, without the hand-over's" do
    expect(created.to_file.keys).to eq(%w[metadata_version id command cwd workspace_root status pid pid_started
                                          created_at started_at finished_at exit_code stop_reason
                                          output_path exit_code_path])
    expect(created.to_file).to include("metadata_version" => 1, "status" => "running", "workspace_root" => Dir.pwd,
                                       "created_at" => "2026-10-14T12:00:00Z", "finished_at" => nil)
  end

  it "puts a handed-over execute's stderr_path between the paths, and handed_over_by and a stop's flag last" do
    handed = created.with(stderr_path: "/s/stderr.log", handed_over_by: "execute", stop_requested_by: "user")

    expect(handed.to_file.keys.last(5)).to eq(%w[output_path stderr_path exit_code_path handed_over_by stop_requested_by])
  end

  it "reads back what it wrote, byte for byte" do
    text = JSON.pretty_generate(created.to_file)

    expect(JSON.pretty_generate(described_class.from_file(JSON.parse(text)).to_file)).to eq(text)
  end

  it "reads a key a file lacks as nil, and no object as no record" do
    expect(described_class.from_file({ "id" => "x" })).to have_attributes(id: "x", status: nil, running?: false)
    expect(described_class.from_file([])).to be_nil
  end

  it "says whether the user stopped it" do
    expect(created.with(stop_reason: "stopped_by_user")).to be_stopped_by_user
    expect(created.with(stop_reason: "stopped_by_model")).not_to be_stopped_by_user
  end
end
