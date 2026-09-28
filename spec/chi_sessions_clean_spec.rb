# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/session"

RSpec.describe "chi sessions clean" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }
  let(:xdg_state) { Dir.mktmpdir("chi-sessions-clean") }
  let(:state_dir) { Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg_state }) }

  after { FileUtils.rm_rf(xdg_state) }

  def run_chi(*args)
    Open3.capture3({ "XDG_STATE_HOME" => xdg_state }, RbConfig.ruby, chi, "sessions", *args, stdin_data: "")
  end

  def make(test_run:, days_old: 0, scratch: false)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: test_run,
                                    scratch: scratch).tap do |s|
      s.messages = [{ role: "user", content: "hi" }, { role: "model", content: "hello" }]
      s.save(state_dir: state_dir)
      next if days_old.zero?

      path = File.join(state_dir, "#{s.id}.json")
      data = JSON.parse(File.read(path))
      data["updated_at"] = (Time.now - days_old * 86_400).iso8601(3)
      File.write(path, JSON.generate(data))
    end
  end

  def exists?(session) = File.exist?(File.join(state_dir, "#{session.id}.json"))

  it "deletes every test session whatever its age, and no other" do
    fresh_test = make(test_run: true)
    old_test = make(test_run: true, days_old: 30)
    fresh_real = make(test_run: false)

    out, err, status = run_chi("clean")

    expect(status.exitstatus).to eq(0), err
    expect(out).to start_with("Deleted 2 sessions")
    expect([exists?(fresh_test), exists?(old_test), exists?(fresh_real)]).to eq([false, false, true])
  end

  it "with --days N takes only the test sessions older than N days" do
    fresh_test = make(test_run: true)
    old_test = make(test_run: true, days_old: 30)

    out, err, status = run_chi("clean", "--days", "7")

    expect(status.exitstatus).to eq(0), err
    expect(out).to start_with("Deleted 1 sessions")
    expect([exists?(fresh_test), exists?(old_test)]).to eq([true, false])
  end

  it "deletes a chi scratch session its process left behind" do
    leftover = make(test_run: false, scratch: true)
    real = make(test_run: false)

    out, err, status = run_chi("clean")

    expect(status.exitstatus).to eq(0), err
    expect(out).to start_with("Deleted 1 sessions")
    expect([exists?(leftover), exists?(real)]).to eq([false, true])
  end
end
