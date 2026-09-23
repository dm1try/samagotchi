# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"
require "samagotchi/web/app"
require "samagotchi/session"

# The web's image surface: upload (paste/drop) and serve, a turn's refs,
# and images in the history it shows.
RSpec.describe Samagotchi::Web::App, "images" do
  let(:state_dir) { Dir.mktmpdir("web-images") }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd).tap do |s|
      s.save(state_dir: state_dir)
    end
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }
  let(:png) { File.binread(File.expand_path("../fixtures/images/tiny.png", __dir__)) }
  let(:manager) do
    Class.new do
      attr_reader :inputs, :spawned

      def initialize = (@inputs = []; @spawned = [])
      def resume_session(*, **) = nil
      def session_owner(*, **) = nil

      def spawn_session(prompt:, state_dir: nil, **)
        @spawned << prompt
        Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd).tap { |s| s.save(state_dir: state_dir) }
      end

      def write_turn_input(id, **options)
        Samagotchi::SessionManager.write_turn_input(id, **options).tap { |path| @inputs << path }
      end
    end.new
  end
  let(:app) { described_class.new(manager: manager, state_dir: state_dir, session_class: Samagotchi::Session, bridge_wait_timeout: 0) }

  before { allow(app).to receive(:live_bridge_client).and_return(nil) }
  after { FileUtils.rm_rf(state_dir) }

  def call(path, method: "GET", body: nil, headers: {})
    status, headers, chunks = app.call(Rack::MockRequest.env_for(path, "HTTP_HOST" => "127.0.0.1", method: method, input: body, **headers))
    [status, headers, chunks.to_a.join]
  end

  def upload(bytes = png, name: "paste.png")
    call("/api/sessions/#{session.id}/images?name=#{name}", method: "POST", body: bytes, headers: { "CONTENT_TYPE" => "image/png" })
  end

  describe "POST /api/sessions/:id/images" do
    it "stores the image and answers its ref" do
      status, _, body = upload
      ref = JSON.parse(body)
      expect(status).to eq(201)
      expect(ref).to include("mime" => "image/png", "width" => 3, "height" => 2, "name" => "paste.png", "source" => "user")
      expect(File.binread(File.join(session_dir, ref["file"]))).to eq(png)
    end

    it "refuses what isn't an image (422), an unknown session (404), and over 20 MB (413)" do
      expect(upload("plain text").first).to eq(422)
      expect(call("/api/sessions/nope/images", method: "POST", body: png).first).to eq(404)
      big = call("/api/sessions/#{session.id}/images", method: "POST", body: png, headers: { "CONTENT_LENGTH" => (21 * 1024 * 1024).to_s })
      expect(big.first).to eq(413)
    end
  end

  describe "GET /api/sessions/:id/images/:name" do
    it "serves a stored image with its type and nosniff" do
      ref = JSON.parse(upload.last)
      status, headers, body = call("/api/sessions/#{session.id}/#{ref["file"]}")
      expect(status).to eq(200)
      expect(headers).to include("Content-Type" => "image/png", "X-Content-Type-Options" => "nosniff")
      expect(body.b).to eq(png)
    end

    it "404s for other names, traversal and other sessions' ids" do
      upload
      ["x.png", "#{"0" * 16}.svg", "..%2F..%2Fetc%2Fpasswd", "#{"0" * 16}.png"].each do |name|
        expect(call("/api/sessions/#{session.id}/images/#{name}").first).to eq(404), name
      end
      expect(call("/api/sessions/..%2F..%2Fx/images/#{"0" * 16}.png").first).to eq(404)
    end
  end

  describe "POST /api/sessions/:id/turn with images" do
    def turn(images)
      call("/api/sessions/#{session.id}/turn", method: "POST", body: JSON.generate(prompt: "look", client_id: "web:1", images: images))
    end

    it "queues refs to uploads" do
      ref = JSON.parse(upload.last)
      status, = turn([ref])
      expect(status).to eq(202)
      expect(JSON.parse(File.read(manager.inputs.last))["images"]).to eq([{ "file" => ref["file"], "name" => "paste.png" }])
    end

    it "refuses a path, traversal and unknown files" do
      [[{ path: "/etc/passwd" }], [{ file: "../../etc/passwd" }], [{ file: "images/#{"0" * 16}.png" }]].each do |images|
        status, _, body = turn(images)
        expect([status, JSON.parse(body)["error"]]).to eq([400, "bad_images"]), images.inspect
      end
      expect(manager.inputs).to be_empty
    end

    it "refuses images for a worker that predates them (format 2)" do
      ref = JSON.parse(upload.last)
      File.write(File.join(session_dir, "bridge.json"), JSON.generate("port" => 1, "session_id" => session.id, "input_format" => 2))
      status, _, body = turn([ref])
      expect([status, JSON.parse(body)["error"]]).to eq([409, "images_unsupported"])
    end
  end

  it "creates an idle session for a first message with images" do
    status, _, body = call("/api/sessions", method: "POST", body: JSON.generate(idle: true))
    expect(status).to eq(201)
    expect(manager.spawned).to eq([nil])
    expect(JSON.parse(body)["id"]).to be_a(String)
  end

  it "shows a user message's images in the history" do
    ref = JSON.parse(upload.last)
    session.messages = [{ role: "user", content: "look", images: [ref.transform_keys(&:to_sym)] }, { role: "model", content: "red" }]
    session.save(state_dir: state_dir)
    allow(app).to receive(:bridge_get_json).and_return(nil)

    _, _, body = call("/api/sessions/#{session.id}")
    user = JSON.parse(body)["messages"].find { |m| m["role"] == "user" }
    expect(user["images"]).to eq([{ "file" => ref["file"], "name" => "paste.png", "width" => 3, "height" => 2 }])
  end
end
