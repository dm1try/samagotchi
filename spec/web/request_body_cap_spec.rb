# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/grants"
require "samagotchi/participants"
require "samagotchi/bridge"
require_relative "../support/counting_input"

# Every body chi web reads is capped (Web::RequestBody#request_body): 64 KB
# unless the call names its cap. Over it, by Content-Length (nothing read)
# or by what came (a chunked body: at most the cap + 1 read), the answer is
# App#route's one 413 too_large, with Connection: close. The bodies here
# are made as they are read (CountingInput), so a 300 MB one costs nothing.
RSpec.describe Samagotchi::Web::App, "request body caps" do
  let(:token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:lan_ip) { "192.168.1.55" }
  let(:root) { File.realpath(Dir.mktmpdir("web-body-cap")) }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:grants) { Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: state_dir)) }
  let(:app) do
    described_class.new(state_dir: state_dir, bridge_wait_timeout: 0, grants: grants, lan: { ip: lan_ip, token: token })
  end
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root).tap do |s|
      s.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
    end
  end
  let(:issued) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir) }
  let(:huge) { 300 * 1024 * 1024 }
  let(:small) { 64 * 1024 }

  after { FileUtils.remove_entry(root) }

  # +input+ a CountingInput (or a String); +length+ the Content-Length to
  # declare (nil: none, the body chunked).
  def post(path, input, as: issued.token, length: input.size, content_type: "application/json", method: "POST")
    input = CountingInput.new(input.bytesize, prefix: input) if input.is_a?(String)
    env = Rack::MockRequest.env_for(path, method: method, input: input)
    env.delete("CONTENT_LENGTH")
    env["CONTENT_LENGTH"] = length.to_s if length
    env["HTTP_TRANSFER_ENCODING"] = "chunked" unless length
    env["CONTENT_TYPE"] = content_type
    env["HTTP_HOST"] = "#{lan_ip}:4567"
    env["REMOTE_ADDR"] = "192.168.1.20"
    env["HTTP_AUTHORIZATION"] = "Bearer #{as}" if as
    status, headers, chunks = app.call(env)
    text = +""
    chunks.each { |c| text << c }
    [status, headers, text, input]
  end

  def session_path(tail) = "/api/sessions/#{session.id}/#{tail}"

  # A JSON object of exactly +bytes+ bytes.
  def json_of(bytes)
    shell = JSON.generate({ pad: "" })
    JSON.generate({ pad: "a" * (bytes - shell.bytesize) })
  end

  it "answers a participant's 300 MB /cancel by its Content-Length 413, reading nothing, the connection closed" do
    status, headers, text, input = post(session_path("cancel"), CountingInput.new(huge))

    expect(status).to eq(413)
    expect(JSON.parse(text)).to eq({ "error" => "too_large", "detail" => "a request body may be up to 64 KB" })
    expect(headers["Connection"]).to eq("close")
    expect(input.bytes_read).to eq(0)
  end

  it "stops a chunked body (no Content-Length) after the cap + 1 bytes" do
    status, _headers, _text, input = post(session_path("cancel"), CountingInput.new(huge), length: nil)

    expect(status).to eq(413)
    expect(input.bytes_read).to eq(small + 1)
  end

  it "stops a body longer than its Content-Length says after the cap + 1 bytes" do
    status, _headers, _text, input = post(session_path("cancel"), CountingInput.new(huge), length: 10)

    expect(status).to eq(413)
    expect(input.bytes_read).to eq(small + 1)
  end

  it "takes a body of the cap and refuses one byte more (wait/prepare)" do
    expect(post(session_path("wait/prepare"), json_of(small)).first).not_to eq(413)
    expect(post(session_path("wait/prepare"), json_of(small + 1)).first).to eq(413)
  end

  it "answers a participant's dequeue, wait and cancel 413" do
    %w[turn/e1/dequeue wait cancel wait/prepare].each do |tail|
      expect(post(session_path(tail), CountingInput.new(small + 1)).first).to eq(413), tail
    end
  end

  describe "a turn" do
    let(:limit) { Samagotchi::Web::RequestBody::BRIDGE_BODY_LIMIT }

    it "caps a participant's at what the Bridge takes (its MAX_BODY_BYTES)" do
      expect(limit).to eq(Samagotchi::Bridge::MAX_BODY_BYTES)
      allow(app).to receive(:handle_participant_turn).and_return([202, {}, ["{}"]])

      status, _headers, text, = post(session_path("turn"), CountingInput.new(limit + 1))
      expect([status, JSON.parse(text)["detail"]]).to eq([413, "a request body may be up to 1 MB"])
      expect(app).not_to have_received(:handle_participant_turn)

      expect(post(session_path("turn"), JSON.generate({ prompt: "a" * (limit - 100) })).first).to eq(202)
      expect(app).to have_received(:handle_participant_turn)
    end

    it "takes an owner's 2 MB prompt to delivery, and refuses 16 MB + 1 by its Content-Length" do
      result = Struct.new(:status, :ack, :via).new(:accepted, {}, :bridge)
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(result)
      allow(app).to receive_messages(turn_refusal: nil, record_history: nil)

      status, = post(session_path("turn"), JSON.generate({ prompt: "a" * (2 * 1024 * 1024) }), as: token)
      expect(status).to eq(202)
      expect(Samagotchi::SessionManager).to have_received(:deliver_turn).with(session.id, hash_including(prompt: "a" * (2 * 1024 * 1024)))

      cap = Samagotchi::Web::App::OWNER_TURN_BODY_LIMIT
      status, _headers, text, input = post(session_path("turn"), CountingInput.new(cap + 1), as: token)
      expect([status, JSON.parse(text)["detail"], input.bytes_read]).to eq([413, "a request body may be up to 16 MB", 0])
    end
  end

  it "answers a huge body without a token 401, reading nothing" do
    status, _headers, _text, input = post(session_path("cancel"), CountingInput.new(huge), as: nil)

    expect(status).to eq(401)
    expect(input.bytes_read).to eq(0)
  end

  describe "the explicit caps" do
    def detail(status_text) = [status_text[0], JSON.parse(status_text[2])["detail"], JSON.parse(status_text[2])["error"]]

    it "keeps render's 64 KB text, the image's 20 MB and update's 16 KB, each too_large" do
      render_cap = Samagotchi::Web::MessageDisplay::MAX_RENDER_BYTES
      expect(detail(post("/api/render", CountingInput.new(render_cap + 1), as: token)))
        .to eq([413, "a text to render may be up to 64 KB", "too_large"])

      image_cap = Samagotchi::Web::SessionControl::MAX_IMAGE_UPLOAD_BYTES
      expect(detail(post(session_path("images"), CountingInput.new(image_cap + 1), as: token, content_type: "image/png")))
        .to eq([413, "an image may be up to 20 MB", "too_large"])

      app.instance_variable_set(:@hub, Object.new)
      expect(detail(post("/api/update", CountingInput.new(16_385), as: token)))
        .to eq([413, "an update request may be up to 16 KB", "too_large"])
    end

    it "keeps the trade's boundary: a 4096-byte /api/token body is no token (401), 4095 is read" do
      body = ->(bytes) { JSON.generate({ token: token, pad: "" }).then { |s| s.sub('""', "\"#{"a" * (bytes - s.bytesize)}\"") } }

      expect(post("/api/token", body.call(4096), as: nil).first).to eq(401)
      expect(post("/api/token", body.call(4095), as: nil).first).to eq(204)
      expect(post("/api/token", CountingInput.new(huge), as: nil).then { |r| [r[0], r[3].bytes_read] }).to eq([401, 0])
    end

    it "answers a stop's truncated wait 413, no longer the default wait" do
      expect(post(session_path("stop"), json_of(4097), as: token).first).to eq(413)
    end
  end

  describe Samagotchi::Web::RequestBody do
    it "words each cap in the 413" do
      expect([65_536, 20 * 1024 * 1024, 1_000_000, 16_384, 1000].map { |b| described_class.size_words(b) })
        .to eq(["64 KB", "20 MB", "1 MB", "16 KB", "1000 bytes"])
    end

    it "keeps the owner's turn cap within what the Bridge skips before its own 413" do
      expect(described_class::OWNER_TURN_BODY_LIMIT).to be <= 32 * Samagotchi::Bridge::MAX_BODY_BYTES
    end
  end
end
