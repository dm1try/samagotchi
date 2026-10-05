# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"

# The route table: which handler every method + path reaches (with which
# captures), what a wrong method or an unknown path gets, and that the Host,
# cross-site and LAN token gates answer before any route.
RSpec.describe Samagotchi::Web::App, "routing" do
  let(:state_dir) { Dir.mktmpdir("web-routing") }
  let(:public_dir) do
    Dir.mktmpdir("web-routing-public").tap do |dir|
      File.write(File.join(dir, "index.html"), "<html>chi</html>")
      File.write(File.join(dir, "app.js"), "// app")
    end
  end
  let(:lan) { nil }
  let(:app) { described_class.new(state_dir: state_dir, public_dir: public_dir, bridge_wait_timeout: 0, lan: lan) }

  let(:handlers) do
    %i[serve_index handle_list handle_create handle_info handle_models handle_events handle_stream
       handle_output handle_cancel handle_stop handle_archive handle_unarchive handle_turn
       handle_question_answer handle_question_dismiss handle_command handle_image_upload handle_image
       handle_show handle_delete handle_context_list handle_context_show handle_context_delete]
  end

  before do
    handlers.each do |name|
      allow(app).to receive(name) do |*args|
        captures = args.reject { |a| a.is_a?(Rack::Request) }
        [299, { "Content-Type" => "application/json" }, [JSON.generate(handler: name.to_s, captures: captures)]]
      end
    end
  end

  after do
    FileUtils.remove_entry(state_dir)
    FileUtils.remove_entry(public_dir)
  end

  def call(path, method: "GET", host: "127.0.0.1:4567", peer: "127.0.0.1", env: {})
    rack_env = Rack::MockRequest.env_for(path, method: method).merge(env)
    rack_env["HTTP_HOST"] = host
    rack_env["REMOTE_ADDR"] = peer
    status, headers, chunks = app.call(rack_env)
    text = +""
    chunks.each { |c| text << c }
    [status, headers, text]
  end

  def routed(path, method: "GET")
    status, _headers, body = call(path, method: method)
    return [status, body] unless status == 299

    parsed = JSON.parse(body)
    [parsed["handler"], *parsed["captures"]]
  end

  it "answers 404 for a session id that isn't one on every /api/sessions/:id route, before any handler" do
    routes = [["GET", "stream"], ["GET", "output"], ["POST", "cancel"], ["POST", "stop"], ["POST", "archive"],
              ["POST", "unarchive"], ["POST", "turn"], ["POST", "answer"], ["POST", "question/dismiss"],
              ["POST", "command"], ["POST", "images"], ["GET", "images/abc.png"], ["GET", nil], ["DELETE", nil],
              ["GET", "context"], ["GET", "context/pr-1"], ["DELETE", "context/pr-1"]]
    ["..", "..%2Fx", "%2Ftmp", "a%00b", "a%2Fb", "x.json"].each do |id|
      routes.each do |method, tail|
        path = ["/api/sessions/#{id}", tail].compact.join("/")
        status, body = routed(path, method: method)
        expect(status).to eq(404), "#{method} #{path}"
        expect(JSON.parse(body)["error"]).to eq("not_found")
      end
    end
    expect(routed("/api/sessions/#{"a" * 8}-1234", method: "DELETE")).to eq(["handle_delete", "#{"a" * 8}-1234"])
  end

  it "sends every route to its handler with the path's captures" do
    table = {
      ["GET", "/"] => ["serve_index"],
      ["GET", "/index.html"] => ["serve_index"],
      ["GET", "/api/sessions"] => ["handle_list"],
      ["POST", "/api/sessions"] => ["handle_create"],
      ["GET", "/api/info"] => ["handle_info"],
      ["GET", "/api/models"] => ["handle_models"],
      ["GET", "/api/events"] => ["handle_events"],
      ["GET", "/api/sessions/s1/stream"] => %w[handle_stream s1],
      ["GET", "/api/sessions/s1/output"] => %w[handle_output s1],
      ["POST", "/api/sessions/s1/cancel"] => %w[handle_cancel s1],
      ["POST", "/api/sessions/s1/stop"] => %w[handle_stop s1],
      ["POST", "/api/sessions/s1/archive"] => %w[handle_archive s1],
      ["POST", "/api/sessions/s1/unarchive"] => %w[handle_unarchive s1],
      ["POST", "/api/sessions/s1/turn"] => %w[handle_turn s1],
      ["POST", "/api/sessions/s1/answer"] => %w[handle_question_answer s1],
      ["POST", "/api/sessions/s1/question/dismiss"] => %w[handle_question_dismiss s1],
      ["POST", "/api/sessions/s1/command"] => %w[handle_command s1],
      ["POST", "/api/sessions/s1/images"] => %w[handle_image_upload s1],
      ["GET", "/api/sessions/s1/images/abc.png"] => ["handle_image", "s1", "abc.png"],
      ["GET", "/api/sessions/s1/context"] => %w[handle_context_list s1],
      ["GET", "/api/sessions/s1/context/pr-1"] => %w[handle_context_show s1 pr-1],
      ["DELETE", "/api/sessions/s1/context/pr-1"] => %w[handle_context_delete s1 pr-1],
      ["GET", "/api/sessions/s1"] => %w[handle_show s1],
      ["DELETE", "/api/sessions/s1"] => %w[handle_delete s1]
    }
    table.each do |(method, path), expected|
      expect(routed(path, method: method)).to eq(expected), "#{method} #{path}"
    end
  end

  it "answers a wrong method on a known path with the not-found JSON" do
    [
      ["POST", "/"], ["PUT", "/api/sessions"], ["DELETE", "/api/info"], ["POST", "/api/events"],
      ["GET", "/api/sessions/s1/turn"], ["POST", "/api/sessions/s1/stream"], ["GET", "/api/sessions/s1/archive"],
      ["GET", "/api/sessions/s1/question/dismiss"], ["POST", "/api/sessions/s1"], ["PUT", "/api/sessions/s1"],
      ["DELETE", "/api/sessions/s1/images/abc.png"]
    ].each do |method, path|
      status, headers, body = call(path, method: method)
      expect([status, headers["Content-Type"], JSON.parse(body)])
        .to eq([404, "application/json; charset=utf-8", { "error" => "not_found", "detail" => "not found: #{path}" }]), "#{method} #{path}"
    end
  end

  it "answers an unknown path with the not-found JSON" do
    ["/nope", "/api/nope", "/api/sessions/s1/nope", "/api/sessions/s1/images/a/b", "/api/sessions/"].each do |path|
      status, _headers, body = call(path)
      expect([status, JSON.parse(body)]).to eq([404, { "error" => "not_found", "detail" => "not found: #{path}" }]), path
    end
  end

  it "serves public files at the root, under /assets/ and /public/, for any method" do
    ["/app.js", "/assets/app.js", "/public/app.js"].each do |path|
      status, _headers, body = call(path)
      expect([status, body]).to eq([200, "// app"]), path
    end
    expect(call("/app.js", method: "POST")[0]).to eq(200)
    expect(call("/assets/nope.js")[0]).to eq(404)
  end

  it "checks the Host before the cross-site gate, and both before any route" do
    status, _headers, body = call("/api/sessions", host: "evil.example")
    expect([status, JSON.parse(body)["error"]]).to eq([403, "forbidden"])
    status, _headers, body = call("/api/nope", host: "evil.example", env: { "HTTP_ORIGIN" => "https://evil.example" })
    expect([status, JSON.parse(body)["error"]]).to eq([403, "forbidden"])

    status, _headers, body = call("/api/nope", env: { "HTTP_SEC_FETCH_SITE" => "cross-site" })
    expect([status, JSON.parse(body)["error"]]).to eq([403, "cross_origin"])
    status, _headers, body = call("/api/sessions/s1/turn", method: "POST", env: { "HTTP_ORIGIN" => "https://evil.example" })
    expect([status, JSON.parse(body)["error"]]).to eq([403, "cross_origin"])
  end

  context "in LAN mode" do
    let(:lan) { { ip: "192.168.1.55", token: "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" } }

    it "asks a LAN peer for the token before any route, after the Host and cross-site gates" do
      phone = { host: "192.168.1.55:4567", peer: "192.168.1.20" }
      status, _headers, body = call("/api/sessions/s1", **phone)
      expect([status, JSON.parse(body)["error"]]).to eq([401, "unauthorized"])
      expect(call("/api/nope", **phone)[0]).to eq(401)
      expect(call("/app.js", **phone)[0]).to eq(401)
      expect(call("/api/sessions", host: "evil.example", peer: "192.168.1.20")[0]).to eq(403)
      expect(JSON.parse(call("/api/sessions", **phone, env: { "HTTP_SEC_FETCH_SITE" => "cross-site" })[2])["error"])
        .to eq("cross_origin")

      authed = { "HTTP_AUTHORIZATION" => "Bearer #{lan[:token]}" }
      expect(JSON.parse(call("/api/sessions/s1", **phone, env: authed)[2])["handler"]).to eq("handle_show")
      expect(routed("/api/sessions/s1")).to eq(%w[handle_show s1]) # loopback: no token
    end
  end

  it "answers a handler's exception with a 500 JSON" do
    allow(app).to receive(:handle_info).and_raise(RuntimeError, "boom")
    status, _headers, body = call("/api/info")
    expect([status, JSON.parse(body)]).to eq([500, { "error" => "internal_error", "detail" => "boom" }])
  end
end
