# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"

# `chi memory` through bin/chi: the wiring (argv, streams, exit codes, the
# memories from XDG_CONFIG_HOME, the project from the cwd). One real run,
# the other forked (ChiCli#fork_chi); MemoryCommand's own spec has the rest.
RSpec.describe "chi memory (CLI)" do
  let(:tmp) { Dir.mktmpdir("chi-memory") }
  let(:work) { File.join(tmp, "work").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:system_dir) { File.join(tmp, "config", "samagotchi", "memories") }

  after { FileUtils.rm_rf(tmp) }

  def chi_memory(*args, spawn: false) = run_or_fork_chi("memory", *args, spawn: spawn, env: isolated_chi_env(tmp), chdir: work)

  it "lists the memories and removes one into the bundle trash" do
    FileUtils.mkdir_p(system_dir)
    File.write(File.join(system_dir, "notes.md"), "hello\n")
    File.write(File.join(system_dir, "index.md"), "# Memory Index\n\n- **notes** · system · 2026-10-20 · 6 — Team notes\n")

    out, err, status = chi_memory("ls", spawn: true)
    expect([out, err, status.exitstatus]).to eq(["system  notes  6  2026-10-20  Team notes\n", "", 0])

    out, err, status = chi_memory("rm", "notes")
    expect([err, status.exitstatus]).to eq(["", 0])
    trash = Dir.glob(File.join(system_dir, ".bundles", ".trash", "memory-notes-*")).first
    expect(out).to eq("Memory 'notes' removed from system scope: moved to #{trash} " \
                      "(`chi bundle trash` lists and empties it); index line dropped.\n")
    expect(File.read(File.join(system_dir, "index.md"))).not_to include("notes")
  end

  it "reports usage from the sessions its state dir holds" do
    FileUtils.mkdir_p(system_dir)
    File.write(File.join(system_dir, "notes.md"), "hello\n")
    File.write(File.join(system_dir, "index.md"), "# Memory Index\n\n- **notes** · system · 2026-10-20 · 6 — Team notes\n")
    sessions = File.join(tmp, "state", "samagotchi", "sessions")
    FileUtils.mkdir_p(sessions)
    File.write(File.join(sessions, "one.json"), JSON.generate({
      "metadata_version" => 3, "id" => "one", "mode" => "assist", "model_name" => "gemma",
      "working_directory" => work, "messages" => [
                                     { "role" => "user", "content" => "go" },
                                     { "role" => "model", "content" => "", "tool_calls" => [{ "id" => "c1", "name" => "memory_read", "arguments" => { "name" => "notes" } }] },
                                     { "role" => "tool_response", "tool_call_id" => "c1", "content" => "[memory_read]\nhello\n" }
                                   ],
      "created_at" => "2026-11-01T10:00:00.000Z", "updated_at" => "2026-11-01T10:00:00.000Z", "status" => "idle"
    }))

    out, err, status = chi_memory("usage", "--format", "json")
    expect([err, status.exitstatus]).to eq(["", 0])
    json = JSON.parse(out)
    expect(json["sessions"]).to eq(1)
    expect(json["reads"]).to eq({ "count" => 1, "tokens" => 5, "cut_reads" => 0, "names" => 1 })

    out, _, status = chi_memory("usage")
    expect(status.exitstatus).to eq(0)
    expect(out).to include("1 session over 0 days")
    expect(out).to include("Most read, by tokens (these 1 of 1: 100% of 5 read tokens)")
  end
end
