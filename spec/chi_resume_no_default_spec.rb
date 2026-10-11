# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "securerandom"
require "samagotchi/session"

# `chi --resume ID` when config.yml names no default.model: the resumed
# session's own model runs, because the session names its model.
RSpec.describe "chi --resume with no default.model" do
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

  # A config with hosts but no default.model: the resumed session's model
  # runs in the REPL (no shared worker).  This is part B: part A made the
  # worker path work; the REPL still needed fixes.
  it "runs the resumed session's own model (no config default)" do
    Dir.mktmpdir do |dir|
      write_config(dir, "hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
      id = save_session(dir, model_name: "main:spec-model")

      out, err, status = run_chi("--resume", id, "--no-shared", env: isolated_chi_env(dir), chdir: dir)

      expect(status.exitstatus).to eq(0), err
      expect(err).to eq("")
      expect(out).to include("Resumed session: #{id}")
      expect(out).to include("model=main:spec-model")
      expect(out).not_to include("(default")
    end
  end

  # --non-interactive with --resume and -p goes to the in-process REPL
  # (attached mode refuses --non-interactive); with no default, it should
  # still run on the session's model.
  it "runs -p --non-interactive on a session model (no config default)" do
    Dir.mktmpdir do |dir|
      write_config(dir, "hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
      id = save_session(dir, model_name: "main:spec-model")

      _out, err, status = run_chi("--no-shared", "--resume", id, "--non-interactive", "-p", "/help",
                                  env: isolated_chi_env(dir), chdir: dir)

      expect(status.exitstatus).to eq(0), err
      expect(err).not_to include("no model configured")
    end
  end

  # A session with model_name: "" and no config default: no source provides
  # a model, so it must fail with the standard error.
  it "fails when the session has no model and there's no default" do
    Dir.mktmpdir do |dir|
      write_config(dir, "hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
      id = save_session(dir, model_name: "")

      out, err, status = run_chi("--resume", id, "--no-shared", env: isolated_chi_env(dir), chdir: dir)

      expect(status.exitstatus).to eq(1)
      expect(out).to eq("")
      expect(err).to eq("Error: no model configured: set default.model in #{dir}/config/samagotchi/config.yml " \
                        "to the model id your server serves (or SAMAGOTCHI_DEFAULT_MODEL, or pass --model ID); " \
                        "see docs/configuration.md; or run: chi bootstrap HOST[:PORT]\n")
    end
  end
end
