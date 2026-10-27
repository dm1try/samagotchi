# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/session_manager"

# chi web's new sessions on a config kit whose groups: is invalid
# (Toolkit.check_new!): whichever handler spawns it, a 400 toolkit_refused
# with the check's one line, and nothing spawned.
RSpec.describe Samagotchi::Web::App, "a toolkit refused at creation" do
  around do |example|
    Dir.mktmpdir("web-kit") do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    end
  end

  let(:state_dir) { File.join(@tmp, "state").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:folder) { File.join(@tmp, "proj").tap { |dir| FileUtils.mkdir_p(File.join(dir, ".git")) } }
  let(:app) do
    described_class.new(manager: Samagotchi::SessionManager, state_dir: state_dir, bridge_wait_timeout: 0,
                        wait_poll_interval: 0.01)
  end
  let(:refusal) do
    "toolkit.kits.typo: groups must be a list of group names or globs; fix config.yml to start a session on toolkit typo"
  end

  before do
    allow(Process).to receive(:spawn).and_return(12_345)
    allow(Samagotchi::Toolkit).to receive(:config_kits)
      .and_return("typo" => { "base" => "lean", "groups" => { "chrome" => true } })
  end

  def create(body)
    env = Rack::MockRequest.env_for("/api/sessions", "HTTP_HOST" => "127.0.0.1", method: "POST",
                                                     input: JSON.generate(body))
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.to_a.join)]
  end

  it "refuses a create on it, named or as toolkit.default" do
    expect(create(prompt: "hi", dir: folder, toolkit: "typo"))
      .to eq([400, { "error" => "toolkit_refused", "detail" => refusal }])
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("toolkit.default").and_return("typo")
    expect(create(prompt: "hi", dir: folder)).to eq([400, { "error" => "toolkit_refused", "detail" => refusal }])
    expect(Process).not_to have_received(:spawn)
  end

  it "refuses a continue of a session saved on it" do
    previous = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: folder,
                                               setup: Samagotchi::SessionSetup.new(toolkit: Samagotchi::Toolkit.new(name: "lean")))
    previous.toolkit = Samagotchi::Toolkit.new(name: "typo")
    previous.status = "idle"
    previous.save(state_dir: state_dir)

    expect(create(prompt: "hi", continues: previous.id))
      .to eq([400, { "error" => "toolkit_refused", "detail" => refusal }])
    expect(Process).not_to have_received(:spawn)
  end
end
