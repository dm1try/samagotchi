# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/web/session_hub"

# No page of chi web's may be framed by another page (clickjacking: a
# same-site page could frame the owner's page and steer clicks into it):
# every HTML answer says so, in every mode, and a frame/embed/object load
# from anywhere but the page's own origin is refused before the gate.
RSpec.describe Samagotchi::Web::App, "framing" do
  let(:state_dir) { Dir.mktmpdir("web-framing") }
  let(:public_dir) do
    Dir.mktmpdir("web-framing-public").tap do |dir|
      File.write(File.join(dir, "index.html"), "<html><body>chi</body></html>")
      File.write(File.join(dir, "participant.html"), "<html><body>p</body></html>")
    end
  end
  let(:lan) { nil }
  let(:app) do
    described_class.new(state_dir: state_dir, public_dir: public_dir, bridge_wait_timeout: 0, lan: lan,
                        hub: Samagotchi::Web::SessionHub.new(state_dir: state_dir))
  end

  after do
    FileUtils.remove_entry(state_dir)
    FileUtils.remove_entry(public_dir)
  end

  def call(path, host: "127.0.0.1:4567", peer: "127.0.0.1", headers: {})
    env = Rack::MockRequest.env_for(path, **headers)
    env["HTTP_HOST"] = host
    env["REMOTE_ADDR"] = peer
    status, headers, = app.call(env)
    [status, headers]
  end

  def frame_headers(headers) = headers.values_at("X-Frame-Options", "Content-Security-Policy")

  it "says DENY and frame-ancestors 'none' on the page, and on the static HTML" do
    expect(frame_headers(call("/").last)).to eq(["DENY", "frame-ancestors 'none'"])
    expect(frame_headers(call("/participant.html").last)).to eq(["DENY", "frame-ancestors 'none'"])
  end

  context "on the LAN" do
    let(:lan) { { ip: "192.168.1.55", token: "t" * 43 } }

    it "says so on the 401 page too" do
      status, headers = call("/", host: "192.168.1.55:4567", peer: "192.168.1.20")
      expect(status).to eq(401)
      expect(frame_headers(headers)).to eq(["DENY", "frame-ancestors 'none'"])
    end
  end

  it "refuses a frame, embed or object load unless it is the page's own origin" do
    %w[iframe frame embed object].each do |dest|
      status, = call("/", headers: { "HTTP_SEC_FETCH_DEST" => dest, "HTTP_SEC_FETCH_SITE" => "same-site" })
      expect(status).to eq(403), dest
      expect(call("/", headers: { "HTTP_SEC_FETCH_DEST" => dest, "HTTP_SEC_FETCH_SITE" => "cross-site" }).first).to eq(403)
      expect(call("/", headers: { "HTTP_SEC_FETCH_DEST" => dest, "HTTP_SEC_FETCH_SITE" => "same-origin" }).first).to eq(200)
    end
    expect(call("/", headers: { "HTTP_SEC_FETCH_DEST" => "document", "HTTP_SEC_FETCH_SITE" => "cross-site" }).first).to eq(200)
  end
end
