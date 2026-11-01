# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plugin/context"
require "samagotchi/plugin_session_state"
require "samagotchi/testing"
require "json"

# ctx.session_dir: the layout core owns and removes with the session.
RSpec.describe Samagotchi::PluginSessionState do
  around { |example| Samagotchi::Testing::Sandbox.with { |sandbox| @sandbox = sandbox; example.run } }

  let(:recorder) { Samagotchi::Testing::Recorder.new(cwd: "/work") }
  let(:host) { Samagotchi::Testing::Host.build(recorder) }
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "b", label: "plugin.rb (bundle b)", settings: {}, host: host) }
  let(:id) { "11111111-2222-3333-4444-555555555555" }

  before { recorder.set(session_id: id) }

  it "gives a session's own folder under the bundle's data dir, created, for the session now" do
    expect(ctx.session_dir).to eq(File.join(ctx.data_dir, "sessions", id))
    expect(File).to be_directory(ctx.session_dir)

    recorder.set(session_id: "other")
    expect(ctx.session_dir).to eq(File.join(ctx.data_dir, "sessions", "other"))
  end

  it "is nil with no session yet, or an id that could name a path outside the folder" do
    recorder.set(session_id: nil)
    expect(ctx.session_dir).to be_nil

    recorder.set(session_id: "../x")
    expect(ctx.session_dir).to be_nil
    expect(Dir.children(ctx.data_dir)).to eq([])
  end

  it "only names the folder with create: false, and the writers' call still makes it" do
    path = File.join(ctx.data_dir, "sessions", id)
    expect(ctx.session_dir(create: false)).to eq(path)
    expect(File).not_to exist(path)

    expect(ctx.session_dir).to eq(path)
    expect(File).to be_directory(path)
  end

  it "is nil with create: false too with no session, or an id that isn't plain" do
    recorder.set(session_id: nil)
    expect(ctx.session_dir(create: false)).to be_nil

    recorder.set(session_id: "../x")
    expect(ctx.session_dir(create: false)).to be_nil
  end

  it "takes in an older bundle's file for a reader too: a running session keeps it" do
    old = File.join(ctx.data_dir, "sessions", "#{id}.json")
    FileUtils.mkdir_p(File.dirname(old))
    File.write(old, %({"cap":9}))

    expect(File.read(File.join(ctx.session_dir(create: false), "state.json"))).to eq(%({"cap":9}))
    expect(File).not_to exist(old)
  end

  # What the shipped bundles do with it: a session that never saved anything
  # leaves no folder, one that saves still can.
  {
    "cost-cap" => ["/cap 5", %i[before_generation]],
    "work-cap" => ["/workcap 400", %i[before_generation]],
    "check-in" => ["/checkin 5", %i[before_turn]]
  }.each do |name, (save, reads)|
    it "#{name} leaves no folder when it only reads, and saves into one" do
      bundle = Samagotchi::Testing::Bundle.shipped(name, host: { session_id: id }, sandbox: @sandbox)
      reads.each { |event| bundle.fire(event) }
      folder = File.join(Samagotchi::Paths.state_dir, "plugins", name, "sessions", id)
      expect(File).not_to exist(folder)

      bundle.command(save)
      expect(JSON.parse(File.read(File.join(folder, "state.json")))).to be_a(Hash)
    ensure
      bundle&.shutdown
    end
  end

  it "goes when the session does" do
    File.write(File.join(ctx.session_dir, "state.json"), "{}")
    dir = ctx.session_dir
    described_class.remove(id)
    expect(File).not_to exist(dir)
  end

  it "takes in the file an older bundle kept as sessions/<id>.json, as state.json" do
    old = File.join(ctx.data_dir, "sessions", "#{id}.json")
    FileUtils.mkdir_p(File.dirname(old))
    File.write(old, %({"cap":9}))

    expect(File.read(File.join(ctx.session_dir, "state.json"))).to eq(%({"cap":9}))
    expect(File).not_to exist(old)
  end

  it "leaves that older file when a state.json is already there" do
    FileUtils.mkdir_p(File.join(ctx.data_dir, "sessions", id))
    File.write(File.join(ctx.data_dir, "sessions", id, "state.json"), "new")
    old = File.join(ctx.data_dir, "sessions", "#{id}.json")
    File.write(old, "old")

    expect(File.read(File.join(ctx.session_dir, "state.json"))).to eq("new")
    expect(File.read(old)).to eq("old")
  end

  it "still removes that older file with the session" do
    old = File.join(ctx.data_dir, "sessions", "#{id}.json")
    FileUtils.mkdir_p(File.dirname(old))
    File.write(old, "{}")
    expect(described_class.remove(id)).to eq([old])
  end
end
