# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "open3"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/web/session_hub"
require "samagotchi/session"
require "samagotchi/session_manager"

# ?dir= on the list and the page, dir on create, /api/info: the page's
# project scope (plans/project-scope.md §2 "Web").
RSpec.describe Samagotchi::Web::App do
  # Records spawns instead of forking workers (the list is the hub's).
  class ScopeSpawnRecorder
    attr_reader :spawn_calls

    def initialize
      @spawn_calls = []
    end

    def spawn_session(prompt:, state_dir: nil, **kw)
      @spawn_calls << kw
      Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: kw[:working_directory] || Dir.pwd)
    end
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-c", "user.name=x", "-c", "user.email=x@x",
                                  "-c", "init.defaultBranch=main", *args)
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?

    out
  end

  around do |example|
    Dir.mktmpdir("web-scope") do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    end
  end

  let(:state_dir) { File.join(@tmp, "state") }
  let(:manager) { ScopeSpawnRecorder.new }
  let(:hub) { Samagotchi::Web::SessionHub.new(state_dir: state_dir) }
  let(:app) { described_class.new(manager: manager, state_dir: state_dir, bridge_wait_timeout: 0, hub: hub) }
  let(:repo_a) { File.join(@tmp, "alpha").tap { |dir| git("init", "-q", dir) } }
  let(:repo_b) { File.join(@tmp, "beta").tap { |dir| git("init", "-q", dir) } }
  let(:plain) { File.join(@tmp, "plain").tap { |dir| FileUtils.mkdir_p(dir) } }

  def call(path, method: "GET", body: nil)
    status, headers, chunks = app.call(Rack::MockRequest.env_for(path, "HTTP_HOST" => "127.0.0.1", method: method,
                                                                      input: body))
    [status, headers, chunks.join]
  end

  def session_in(dir)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: dir).tap do |s|
      s.save(state_dir: state_dir)
      sleep 0.005
    end
  end

  def q(dir) = Rack::Utils.escape(dir)

  describe "GET /api/sessions?dir=" do
    it "lists the folder's project only, a subfolder included; X-Total-Count counts the same" do
      a1 = session_in(repo_a)
      session_in(repo_b)
      a2 = session_in(File.join(repo_a, "lib").tap { |dir| FileUtils.mkdir_p(dir) })
      session_in(plain)
      hub.scan

      _, _, body = call("/api/sessions?dir=#{q(repo_a)}")
      expect(JSON.parse(body).map { |s| s["id"] }).to eq([a2.id, a1.id])

      _, headers, body = call("/api/sessions?dir=#{q(repo_a)}&limit=1&offset=1")
      expect(JSON.parse(body).map { |s| s["id"] }).to eq([a1.id])
      expect(headers["X-Total-Count"]).to eq("2")
    end

    it "lists every session without dir or for a folder in no repo" do
      3.times { |i| session_in(i.zero? ? repo_a : plain) }
      hub.scan

      expect(JSON.parse(call("/api/sessions")[2]).size).to eq(3)
      expect(JSON.parse(call("/api/sessions?dir=#{q(plain)}")[2]).size).to eq(3)
    end

    it "answers 400 invalid_dir for a missing or relative folder" do
      [File.join(@tmp, "gone"), "relative/path"].each do |dir|
        status, _, body = call("/api/sessions?dir=#{q(dir)}")
        expect([status, JSON.parse(body)["error"]]).to eq([400, "invalid_dir"])
      end
    end
  end

  describe "POST /api/sessions with dir" do
    it "starts the chat in that folder, and in the server's cwd without one" do
      call("/api/sessions", method: "POST", body: JSON.generate(prompt: "hi", dir: repo_a))
      call("/api/sessions", method: "POST", body: JSON.generate(prompt: "hi"))

      expect(manager.spawn_calls).to eq([{ working_directory: repo_a }, {}])
    end

    it "refuses a folder that doesn't exist" do
      status, _, body = call("/api/sessions", method: "POST", body: JSON.generate(prompt: "hi", dir: "/nope/gone"))

      expect([status, JSON.parse(body)["error"]]).to eq([400, "invalid_dir"])
      expect(manager.spawn_calls).to be_empty
    end
  end

  describe "GET /api/info" do
    it "says it is chi web, with the dir and newest_workers features and the newest installed chi" do
      hub.scan
      status, _, body = call("/api/info")

      expect(status).to eq(200)
      expect(JSON.parse(body)).to include("app" => "chi-web", "version" => Samagotchi::VERSION, "pid" => Process.pid,
                                          "cwd" => Dir.pwd, "features" => %w[dir newest_workers],
                                          "installed" => Samagotchi::VERSION)
    end
  end

  describe "the page" do
    it "carries the project's name and root for a dir in a repo, and where an all-view chat starts" do
      _, _, body = call("/?dir=#{q(File.join(repo_a))}")

      expect(body).to include(%(data-project-name="alpha"))
      expect(body).to include(%(data-project-dir="#{repo_a.sub(Dir.home, "~")}"))
      expect(body).to include(%(data-server-dir="#{Dir.pwd.sub(Dir.home, "~")}"))
    end

    it "names the project an all view came from (?from=), to link back to its view" do
      _, _, body = call("/?from=#{q(repo_a)}")

      expect(body).to include(%(data-back-name="alpha"), %(data-back-dir="#{repo_a}"))
      expect(body).not_to include("data-project-name")
    end

    it "offers the server's own project as the way back when the all view names none" do
      Dir.chdir(repo_b) { expect(call("/")[2]).to include(%(data-back-name="beta"), %(data-back-dir="#{repo_b}")) }
      Dir.chdir(plain) { expect(call("/")[2]).not_to include("data-back-name") }
      Dir.chdir(plain) { expect(call("/?from=#{q(plain)}")[2]).not_to include("data-back-name") }
      Dir.chdir(plain) { expect(call("/?from=%2Fnope")[2]).not_to include("data-back-name") }
    end

    it "has no way back in a project view" do
      expect(call("/?dir=#{q(repo_a)}")[2]).not_to include("data-back-name")
    end

    it "has no project for no dir, a folder in no repo or a bad dir" do
      ["/", "/?dir=#{q(plain)}", "/?dir=%2Fnope"].each do |path|
        expect(call(path)[2]).not_to include("data-project-name")
      end
    end
  end
end
