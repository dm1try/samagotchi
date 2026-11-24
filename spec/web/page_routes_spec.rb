# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "rack/mock"
require "samagotchi/web/app"
require "samagotchi/pages"
require_relative "../support/bundle_pages"

# The pages routes (Web::PageRoutes): the list, a page as stored, Refresh
# (a real runner process through Pages::Launch) and Delete, against a temp
# config and state dir. A participant's token: participant_gate_spec.
RSpec.describe Samagotchi::Web::App, "pages" do
  include BundlePages

  let(:tmp) { Dir.mktmpdir("web-pages") }
  let(:pages) { Samagotchi::Pages }
  let(:store) { Samagotchi::Pages::Store }
  let(:fixtures) { File.expand_path("../fixtures/pages", __dir__) }
  let(:markdown) { false }
  let(:app) do
    described_class.new(state_dir: File.join(tmp, "sessions"), bridge_wait_timeout: 0, markdown: markdown)
  end

  around do |example|
    with_env("XDG_CONFIG_HOME" => File.join(tmp, "config"), "XDG_STATE_HOME" => File.join(tmp, "state")) { example.run }
  ensure
    FileUtils.rm_rf(tmp)
  end

  def script(name, body)
    FileUtils.mkdir_p(pages.scripts_dir)
    File.write(pages.user_script_path(name), body)
  end

  def usage
    FileUtils.mkdir_p(pages.scripts_dir)
    FileUtils.cp(File.join(fixtures, "usage.rb"), pages.script_path("usage"))
    FileUtils.cp(File.join(fixtures, "usage.json"), pages.scripts_dir)
  end

  def call(path, method: "GET")
    env = Rack::MockRequest.env_for(path, "HTTP_HOST" => "127.0.0.1", method: method)
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.to_a.join)]
  end

  describe "GET /api/pages" do
    it "lists none when there is no pages folder" do
      expect(call("/api/pages")).to eq([200, { "pages" => [] }])
    end

    it "lists each page by name: never ran, ran, failed with its line and time, changed" do
      usage
      script("broken", "page('Broken') do |ui|\n  raise 'boom'\nend\n")
      script("idle", "page('Idle') { }\n")
      Samagotchi::Pages::Launch.run("usage")
      Samagotchi::Pages::Launch.run("broken")
      File.write(pages.script_path("usage"), "#{File.read(pages.script_path("usage"))}\n# edited\n")

      status, body = call("/api/pages")
      expect(status).to eq(200)
      rows = body["pages"]
      expect(rows.map { |row| row["name"] }).to eq(%w[broken idle usage])
      broken, idle, used = rows
      expect(broken).to include("state" => "failed", "error_line" => 2, "ran_at" => nil, "changed" => false)
      expect(broken["failed_at"]).to eq(store.read("broken").error.at)
      expect(idle).to eq("name" => "idle", "title" => nil, "state" => "never_ran", "ran_at" => nil, "failed_at" => nil,
                         "changed" => false, "error_line" => nil, "bundle" => nil)
      expect(used).to include("title" => "Usage, last 7 days", "state" => "ok", "changed" => true, "failed_at" => nil)
      expect(used["ran_at"]).to be_a(String)
    end
  end

  describe "GET /api/pages/NAME" do
    it "answers the stored page and runs nothing" do
      usage
      Samagotchi::Pages::Launch.run("usage")
      File.write(File.join(pages.scripts_dir, "usage.json"), "not json") # a run now would fail
      allow(Samagotchi::Pages::Launch).to receive(:run).and_call_original

      status, body = call("/api/pages/usage")
      expect(Samagotchi::Pages::Launch).not_to have_received(:run)
      expect(status).to eq(200)
      expect(body).to include("name" => "usage", "title" => "Usage, last 7 days", "state" => "ok", "changed" => false,
                              "changed_after_failure" => false, "error" => nil)
      expect(body["duration_ms"]).to be_a(Integer)
      expect(body["script_changed_at"]).to eq(File.mtime(pages.script_path("usage")).utc.iso8601)
      expect(body["blocks"][0]).to eq("type" => "text", "text" => "Stored cost per model. 412 turns.")
      expect(body["blocks"][1]["total"]).to eq(["Total", 412, 18.1252])
      expect(body.keys).not_to include("script_sha", "current_sha")
    end

    it "answers a never-ran page with no blocks" do
      script("fresh", "page('Fresh') { }\n")
      expect(call("/api/pages/fresh").last).to include("state" => "never_ran", "blocks" => [], "ran_at" => nil)
    end

    it "says the script changed after a failure, and not before" do
      script("flaky", "page('Flaky') { |ui| ui.text 'ok' }\n")
      Samagotchi::Pages::Launch.run("flaky")
      script("flaky", "page('Flaky') do |ui|\n  raise 'boom'\nend\n")
      Samagotchi::Pages::Launch.run("flaky")
      body = call("/api/pages/flaky").last
      expect(body).to include("state" => "failed", "changed" => true, "changed_after_failure" => false)
      expect(body["error"]).to include("message" => "boom", "line" => 2)
      expect(body["error"].keys).to eq(%w[message line at])

      script("flaky", "page('Flaky') do |ui|\n  raise 'boom again'\nend\n")
      expect(call("/api/pages/flaky").last).to include("changed_after_failure" => true)
    end

    it "answers 404 page_missing for no such script, and for a name that breaks the rule" do
      expect(call("/api/pages/nope")).to eq([404, { "error" => "page_missing", "detail" => "no page nope" }])
      expect(call("/api/pages/Bad%20Name")).to eq([404, { "error" => "page_missing", "detail" => "no page Bad%20Name" }])
      expect(call("/api/pages/..")).to eq([404, { "error" => "page_missing", "detail" => "no page .." }])
      expect(File.exist?(pages.state_dir)).to be(false)
    end

    context "with Markdown rendering available" do
      let(:markdown) { true }

      it "gives a text block the server's sanitised html beside its text" do
        script("md", "page('Md') { |ui| ui.text \"## Head\\n\\n<script>x</script>\\n\\nsee [l](#/p/md)\" }\n")
        Samagotchi::Pages::Launch.run("md")
        block = call("/api/pages/md").last["blocks"].first
        expect(block["text"]).to start_with("## Head")
        html = Nokogiri::HTML5.fragment(block["html"])
        expect(html.at_css("h2").text).to eq("Head")
        expect(html.css("script")).to be_empty
        expect(html.at_css("a")["href"]).to eq("#/p/md")
      end
    end

    it "gives a text block only its text without the renderer" do
      script("md", "page('Md') { |ui| ui.text '## Head' }\n")
      Samagotchi::Pages::Launch.run("md")
      expect(call("/api/pages/md").last["blocks"].first).to eq("type" => "text", "text" => "## Head")
    end
  end

  describe "POST /api/pages/NAME/run" do
    it "runs the script and answers the page as after the run" do
      usage
      status, body = call("/api/pages/usage/run", method: "POST")
      expect(status).to eq(200)
      expect(body).to include("state" => "ok", "title" => "Usage, last 7 days", "error" => nil)
      expect(body["blocks"][1]["rows"]).to include(["claude:sonnet-5-5", 96, 14.221])
      expect(body).not_to have_key("stderr")
    end

    it "answers a failed run with the kept blocks, the error and the script's last words" do
      script("flaky", "page('Flaky') { |ui| ui.text 'good' }\n")
      call("/api/pages/flaky/run", method: "POST")
      script("flaky", "warn 'x' * 3000\nwarn 'last words'\npage('Flaky') do |ui|\n  raise 'boom'\nend\n")

      status, body = call("/api/pages/flaky/run", method: "POST")
      expect(status).to eq(200)
      expect(body).to include("state" => "failed", "blocks" => [{ "type" => "text", "text" => "good" }])
      expect(body["error"]).to include("message" => "boom", "line" => 4)
      expect(body["stderr"]).to end_with("last words\n")
      expect(body["stderr"].bytesize).to be <= 2048
    end

    it "answers 409 page_busy while a run holds the lock" do
      script("held", "page('Held') { }\n")
      store.locked("held") do
        expect(call("/api/pages/held/run", method: "POST"))
          .to eq([409, { "error" => "page_busy", "detail" => "page held is already running" }])
      end
    end

    it "answers 404 page_missing for no such page" do
      expect(call("/api/pages/nope/run", method: "POST")).to eq([404, { "error" => "page_missing", "detail" => "no page nope" }])
    end

    it "answers 503 server_stopping when chi web stops during a run, and stops the run" do
      script("slow", "sleep 20\npage('Slow') { }\n")
      stopping_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
      app.server_running = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) < stopping_at }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      status, body = call("/api/pages/slow/run", method: "POST")
      expect(status).to eq(503)
      expect(body["error"]).to eq("server_stopping")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
      expect(store.read("slow").error.message).to eq("the run was stopped")
    end
  end

  describe "DELETE /api/pages/NAME" do
    it "removes the script and its result" do
      script("gone", "page('Gone') { }\n")
      Samagotchi::Pages::Launch.run("gone")
      expect(call("/api/pages/gone", method: "DELETE")).to eq([200, { "removed" => "gone" }])
      expect(File.exist?(pages.script_path("gone"))).to be(false)
      expect(File.exist?(store.output_dir("gone"))).to be(false)
    end

    it "answers 409 while it runs and 404 for no such page" do
      script("held", "page('Held') { }\n")
      store.locked("held") do
        expect(call("/api/pages/held", method: "DELETE").first).to eq(409)
      end
      expect(call("/api/pages/nope", method: "DELETE"))
        .to eq([404, { "error" => "page_missing", "detail" => "no page nope" }])
    end
  end

  describe "a bundle's page" do
    it "is listed and shown with its bundle, runs, and answers 409 page_bundled to a Delete" do
      scripts = install_page_bundle
      expect(call("/api/pages").last["pages"].map { |row| row.slice("name", "bundle", "state") })
        .to eq([{ "name" => "board", "bundle" => "pager", "state" => "never_ran" }])
      expect(call("/api/pages/board/run", method: "POST").last).to include("state" => "ok", "bundle" => "pager")
      expect(call("/api/pages/board").last).to include("title" => "From the bundle", "bundle" => "pager")

      status, body = call("/api/pages/board", method: "DELETE")
      expect([status, body["error"]]).to eq([409, "page_bundled"])
      expect(body["detail"]).to start_with("page board comes with the pager bundle: uninstall the bundle or write your own ")
      expect(File.file?(File.join(scripts, "board.rb"))).to be(true)
    end
  end
end
