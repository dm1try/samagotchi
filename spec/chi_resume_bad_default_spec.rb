# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "securerandom"
require "samagotchi/session"

# `chi --resume ID` when config.yml's default.model names a host that isn't
# configured: the resumed session's own model is what runs, so the bad
# default must not stop it. (--no-shared forces the in-process REPL, where
# the default is checked.)
RSpec.describe "chi --resume with a bad default.model" do
  def write_config(dir, yaml)
    FileUtils.mkdir_p(File.join(dir, "config", "samagotchi"))
    File.write(File.join(dir, "config", "samagotchi", "config.yml"), yaml)
  end

  def save_session(dir, model_name:)
    state = File.join(dir, "state", "samagotchi", "sessions")
    FileUtils.mkdir_p(state)
    id = SecureRandom.uuid
    File.write(File.join(state, "#{id}.json"), JSON.generate(
      "metadata_version" => 1, "id" => id, "mode" => "assist", "model_name" => model_name,
      "working_directory" => dir, "messages" => [], "created_at" => Time.now.iso8601,
      "updated_at" => Time.now.iso8601, "status" => "idle", "first_preview" => "", "test_run" => true,
      "project_root" => nil, "preloaded_memory_names" => [], "muted_memory_names" => [],
      "parent_id" => nil, "scratch" => false
    ))
    id
  end

  it "runs the resumed session's own model, not the bad default" do
    Dir.mktmpdir do |dir|
      write_config(dir, "default:\n  model: nosuch:org/model\nhosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
      id = save_session(dir, model_name: "main:spec-model")

      out, err, status = run_chi("--resume", id, "--no-shared", env: isolated_chi_env(dir), chdir: dir)

      expect(status.exitstatus).to eq(0), err
      expect(err).to eq("")
      expect(out).to include("Resumed session: #{id}")
      expect(out).to include("model=main:spec-model (default: nosuch:org/model)")
    end
  end

  it "refuses with one line when the resumed session has no model and the default is bad" do
    Dir.mktmpdir do |dir|
      write_config(dir, "default:\n  model: nosuch:org/model\nhosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
      id = save_session(dir, model_name: "")

      out, err, status = run_chi("--resume", id, "--no-shared", env: isolated_chi_env(dir), chdir: dir)

      expect(status.exitstatus).to eq(1)
      expect(out).to eq("")
      expect(err).to eq("Error: unknown host 'nosuch' in model 'nosuch:org/model'; the configured hosts are main\n")
    end
  end
end
