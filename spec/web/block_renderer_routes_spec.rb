# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "digest"
require "yaml"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/memory_bundle/installer"

# What the owner's page asks to draw a fenced block: which languages have a
# renderer, and their files. Owner only: participant_gate_spec walks every
# :owner row. The file route takes names from the URL, so a name that isn't a
# renderer's never becomes a path.
RSpec.describe Samagotchi::Web::App, "block renderer routes" do
  let(:tmpdir) { Dir.mktmpdir("web-block-renderers") }
  let(:bundles_dir) { File.join(Samagotchi::MemoryPaths.system_dir, ".bundles") }
  let(:js) { "chi.defineRenderer({});\n" }
  let(:app) { described_class.new(state_dir: tmpdir, bridge_wait_timeout: 0) }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  after { FileUtils.rm_rf(tmpdir) }

  def install
    src = File.join(tmpdir, "src")
    FileUtils.mkdir_p(File.join(src, "scripts"))
    File.write(File.join(src, "scripts", "draw.js"), js)
    File.write(File.join(src, "scripts", "other.js"), "other()")
    File.write(File.join(src, "manifest.yml"), YAML.dump(
      "name" => "drawer", "version" => "1.0.0", "files" => {},
      "scripts" => { "draw.js" => "sha256:#{Digest::SHA256.hexdigest(js)}", "other.js" => "" },
      "block_renderers" => [{ "lang" => "mermaid", "load" => ["draw.js"] }]
    ))
    Samagotchi::MemoryBundle::Installer.new(source: src, name: "drawer", scope: "system", strict: true).run
  end

  def call(path, headers = {})
    env = Rack::MockRequest.env_for(path, "HTTP_HOST" => "127.0.0.1", **headers)
    status, response_headers, chunks = app.call(env)
    [status, response_headers, chunks.to_a.join]
  end

  it "keeps both routes the owner's: participant_gate_spec walks only the rows that say so" do
    rows = described_class.const_get(:ROUTES).select { |row| row[1].source.include?("block_renderers") }

    expect(rows.map { |row| [row[2], row[3]] })
      .to contain_exactly(%i[handle_block_renderers owner], %i[handle_block_renderer_file owner])
  end

  describe "GET /api/block_renderers" do
    it "is empty with nothing installed" do
      status, _, body = call("/api/block_renderers")

      expect(status).to eq(200)
      expect(JSON.parse(body)).to eq("renderers" => [])
    end

    it "lists each language, its bundle and files" do
      install

      expect(JSON.parse(call("/api/block_renderers").last))
        .to eq("renderers" => [{ "lang" => "mermaid", "bundle" => "drawer", "files" => ["draw.js"] }])
    end
  end

  describe "GET /api/block_renderers/:bundle/:file" do
    before { install }

    it "serves the file as JS, revalidated with an ETag" do
      status, headers, body = call("/api/block_renderers/drawer/draw.js")

      expect(status).to eq(200)
      expect(body).to eq(js)
      expect(headers["Content-Type"]).to start_with("text/javascript")
      expect(headers["Cache-Control"]).to eq("no-cache")
      expect(headers["ETag"]).not_to be_nil

      revalidated = call("/api/block_renderers/drawer/draw.js", "HTTP_IF_NONE_MATCH" => headers["ETag"])
      expect(revalidated.first).to eq(304)
      expect(revalidated.last).to eq("")
    end

    it "refuses a file changed since the install, so the page keeps the source" do
      File.write(File.join(bundles_dir, "drawer", "scripts", "draw.js"), "evil()")

      status, _, body = call("/api/block_renderers/drawer/draw.js")

      expect(status).to eq(409)
      expect(body).not_to include("evil")
      expect(JSON.parse(body)["error"]).to eq("renderer_changed")
    end

    it "is 404 for anything a renderer doesn't load" do
      File.write(File.join(tmpdir, "secret.js"), "the-contents")
      ["/api/block_renderers/drawer/other.js",           # a script, but no load names it
       "/api/block_renderers/drawer/manifest.json",
       "/api/block_renderers/nope/draw.js",
       "/api/block_renderers/../draw.js",
       "/api/block_renderers/drawer/..%2Fmanifest.json",
       "/api/block_renderers/..%2F..%2F/secret.js"].each do |path|
        status, _, body = call(path)
        expect(status).to eq(404), path
        expect(body).not_to include("the-contents"), path
      end
    end
  end
end
