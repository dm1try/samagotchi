# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/grants"
require "samagotchi/participants"
require "samagotchi/participant_uploads"
require "samagotchi/analytics_file"

# A participant's images at chi web: their uploads (POST …/images) within
# their cap, attempts and quota, no converter on their bytes, each answer
# audited; and reading back only what they uploaded (GET …/images/<name>).
RSpec.describe Samagotchi::Web::App, "a participant's images" do
  let(:owner_token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:lan_ip) { "192.168.1.55" }
  let(:root) { Dir.mktmpdir("web-participant-images") }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:grants) { Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: state_dir)) }
  let(:app) do
    described_class.new(state_dir: state_dir, bridge_wait_timeout: 0, grants: grants, lan: { ip: lan_ip, token: owner_token })
  end
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root).tap do |s|
      s.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
    end
  end
  let(:dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }
  let(:issued) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir) }
  let(:grant) { issued.grant }
  let(:other) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Bo", state_dir: state_dir) }
  let(:png) { "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==".unpack1("m") }
  let(:resizer) { instance_double(Samagotchi::ImageResizer, available?: true) }

  before { allow(Samagotchi::ImageResizer).to receive(:detect).and_return(resizer) }

  after { FileUtils.remove_entry(root) }

  def call(path, method: "GET", body: nil, token: issued.token, type: "image/png")
    env = Rack::MockRequest.env_for(path, method: method, input: body, "CONTENT_TYPE" => type)
    env["HTTP_HOST"] = "#{lan_ip}:4567"
    env["REMOTE_ADDR"] = "192.168.1.20"
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}"
    status, headers, chunks = app.call(env)
    [status, headers, chunks.join]
  end

  def upload(bytes, token: issued.token, name: "shot.png")
    status, _headers, body = call("/api/sessions/#{session.id}/images?name=#{name}", method: "POST", body: bytes, token: token)
    [status, JSON.parse(body)]
  end

  def audit = File.readlines(File.join(dir, "participants.jsonl")).map { |line| JSON.parse(line) }
                  .select { |line| line["event"] == "image" }

  # A distinct PNG per +n+ (the header reads the same; the hash differs).
  def png_n(n) = png + "pad#{n}"

  def fill_quota(grant_id = grant.id)
    Samagotchi::Grants::MAX_IMAGES.times do |i|
      Samagotchi::ParticipantUploads.add(dir, file: format("images/%016x.png", i), grant_id: grant_id)
    end
  end

  describe "POST …/images" do
    it "stores their image, records it as theirs, answers the ref without source, mime or bytes, audited" do
      status, body = upload(png)
      expect(status).to eq(201)
      expect(body.keys).to contain_exactly("file", "name", "width", "height")
      expect(body).to include("name" => "shot.png", "width" => 1, "height" => 1)
      expect(body["file"]).to match(Samagotchi::ImageStore::REF_RE)
      expect(File.file?(File.join(dir, body["file"]))).to be(true)
      expect(Samagotchi::ParticipantUploads.owned?(dir, body["file"], grant.id)).to be(true)
      expect(audit.map { |line| line.except("at") })
        .to eq([{ "event" => "image", "participant" => grant.id, "status" => "accepted", "file" => body["file"],
                  "bytes" => png.bytesize }])
      expect(audit.to_s).not_to include("shot.png")
    end

    it "refuses at their cap (429 cap_reached), audited" do
      File.write(Samagotchi::AnalyticsFile.path(dir),
                 JSON.generate({ "turn_records" => [{ "id" => "t1", "author" => grant.author, "cost" => 2.0 }] }))
      expect(upload(png)).to eq([429, { "error" => "cap_reached", "detail" => Samagotchi::ParticipantMessages::CAP_REACHED }])
      expect(audit.map { |line| line.values_at("status", "reason") }).to eq([%w[refused cap_reached]])
      expect(Dir.exist?(File.join(dir, "images"))).to be(false)
    end

    it "refuses at their quota (429 too_many_images, the owned words), storing nothing" do
      fill_quota
      expect(upload(png)).to eq([429, { "error" => "too_many_images",
                                        "detail" => Samagotchi::ParticipantMessages::TOO_MANY_IMAGES }])
      expect(Dir.exist?(File.join(dir, "images"))).to be(false)
      expect(Samagotchi::ParticipantUploads.count(dir, grant.id)).to eq(Samagotchi::Grants::MAX_IMAGES)
      expect(audit.last.values_at("status", "reason")).to eq(%w[refused too_many_images])
    end

    it "accepts again, at quota, a file they own already: no new entry" do
      _, first = upload(png)
      (Samagotchi::Grants::MAX_IMAGES - 1).times do |i|
        Samagotchi::ParticipantUploads.add(dir, file: format("images/%016x.png", i), grant_id: grant.id)
      end
      status, again = upload(png)
      expect(status).to eq(201)
      expect(again["file"]).to eq(first["file"])
      expect(Samagotchi::ParticipantUploads.count(dir, grant.id)).to eq(Samagotchi::Grants::MAX_IMAGES)
    end

    it "keeps another grant's quota apart: theirs full, Bo's not" do
      fill_quota
      expect(upload(png, token: other.token).first).to eq(201)
    end

    it "caps the attempts, refused ones counted (429 too_many_image_attempts)" do
      (Samagotchi::Grants::MAX_IMAGE_ATTEMPTS - 1).times { Samagotchi::ParticipantUploads.attempt!(dir, grant.id) }
      expect(upload("not an image").first).to eq(422)
      expect(upload(png)).to eq([429, { "error" => "too_many_image_attempts",
                                        "detail" => Samagotchi::ParticipantMessages::TOO_MANY_IMAGE_ATTEMPTS }])
      expect(Samagotchi::ParticipantUploads.attempts(dir, grant.id)).to eq(Samagotchi::Grants::MAX_IMAGE_ATTEMPTS)
    end

    {
      "bmp" => "BM#{"\x00" * 30}",
      "tiff" => "II*\x00#{"\x00" * 30}",
      "heic" => "\x00\x00\x00\x18ftypheic#{"\x00" * 20}"
    }.each do |format, bytes|
      it "refuses a #{format} (422 unsupported_image) before any converter runs" do
        expect(resizer).not_to receive(:convert)
        expect(upload(bytes.b)).to eq([422, { "error" => "unsupported_image",
                                              "detail" => Samagotchi::ParticipantMessages::IMAGE_TYPE }])
        expect(Dir.exist?(File.join(dir, "images"))).to be(false)
      end
    end

    it "refuses what isn't an image, an svg too (422 bad_image, the owned words), and an over-size body (413)" do
      ["plain text", %(<svg xmlns="http://www.w3.org/2000/svg"/>)].each do |bytes|
        expect(upload(bytes)).to eq([422, { "error" => "bad_image", "detail" => Samagotchi::ParticipantMessages::BAD_IMAGE }])
      end
      stub_const("Samagotchi::Web::SessionControl::MAX_IMAGE_UPLOAD_BYTES", 10)
      expect(upload(png).first).to eq(413)
      expect(audit.map { |line| line["reason"] }).to eq(%w[bad_image bad_image too_large])
    end

    it "never answers an image tool's words (they may name a host path)" do
      allow(resizer).to receive(:convert).and_raise(Samagotchi::ImageResizer::Error, "sips failed: /private/var/tmp/x/in")
      wide = png.dup
      wide[16, 8] = [5000, 5000].pack("NN")
      status, body = upload(wide)
      expect([status, body]).to eq([422, { "error" => "bad_image", "detail" => Samagotchi::ParticipantMessages::BAD_IMAGE }])
    end

    # A PNG whose header says +w+×+h+ (a decompression bomb's looks like any other).
    def png_sized(w, h, tag = "")
      bytes = png.dup
      bytes[16, 8] = [w, h].pack("NN")
      bytes + tag
    end

    # A resizer that "downscales" to a 1×1 PNG.
    def downscaling
      allow(resizer).to receive(:convert) do |_in, out, **|
        File.binwrite(out, png)
        out
      end
    end

    it "refuses a header over the participant limits, or with no size, before any tool or ingest (422 image_too_big)" do
      expect(Samagotchi::ImageStore).not_to receive(:ingest)
      expect(resizer).not_to receive(:convert)
      [png_sized(60_000, 60_000), png_sized(12_001, 10), png_sized(8000, 6000), png[0, 20]].each do |bytes|
        expect(upload(bytes)).to eq([422, { "error" => "image_too_big", "detail" => Samagotchi::ParticipantMessages::IMAGE_TOO_BIG }])
      end
      expect(audit.map { |line| line["reason"] }.uniq).to eq(%w[image_too_big])
    end

    it "takes a phone photo's size (4032×3024), downscaled one at a time" do
      downscaling
      expect(upload(png_sized(4032, 3024)).first).to eq(201)
    end

    it "refuses at quota a re-upload of their own image that was downscaled (its stored name isn't its bytes')" do
      downscaling
      big = png_sized(4032, 3024)
      expect(upload(big).first).to eq(201)
      (Samagotchi::Grants::MAX_IMAGES - 1).times do |i|
        Samagotchi::ParticipantUploads.add(dir, file: format("images/%016x.png", i), grant_id: grant.id)
      end
      expect(upload(big).first).to eq(429)
    end

    it "checks the quota again after the ingest: a race past it is refused (429), no record" do
      allow(Samagotchi::ImageStore).to receive(:ingest).and_wrap_original do |original, *args, **kwargs|
        fill_quota
        original.call(*args, **kwargs)
      end
      expect(upload(png).first).to eq(429)
      file = Samagotchi::ImageStore.file_name_for(png, :png)
      expect(Samagotchi::ParticipantUploads.owned?(dir, file, grant.id)).to be(false)
      expect(audit.last.values_at("status", "reason")).to eq(%w[refused too_many_images])
    end

    it "counts a cap-refused upload as an attempt" do
      File.write(Samagotchi::AnalyticsFile.path(dir),
                 JSON.generate({ "turn_records" => [{ "id" => "t1", "author" => grant.author, "cost" => 2.0 }] }))
      upload(png)
      expect(Samagotchi::ParticipantUploads.attempts(dir, grant.id)).to eq(1)
    end

    it "audits an upload that raised (internal_error), then answers chi web's 500" do
      allow(Samagotchi::ImageStore).to receive(:ingest).and_raise(RuntimeError, "boom at /private/x")
      allow(Samagotchi::Log).to receive(:exception)
      status, body = upload(png)
      expect([status, body["error"]]).to eq([500, "internal_error"])
      expect(body.to_s).not_to include("/private/x")
      expect(audit.last.values_at("status", "reason")).to eq(%w[refused internal_error])
    end

    it "fails closed on a record that doesn't read: refused, the record left as it was" do
      File.write(File.join(dir, Samagotchi::ParticipantUploads::FILE), "{oops")
      allow(Samagotchi::Log).to receive(:warn)
      expect(upload(png).first).to eq(429)
      expect(File.read(File.join(dir, Samagotchi::ParticipantUploads::FILE))).to eq("{oops")
    end

    it "is 401 for a revoked grant" do
      Samagotchi::Participants.revoke(grants, id: grant.id, state_dir: state_dir)
      expect(upload(png).first).to eq(401)
    end

    it "the owner's upload is as before: the full ref, no record" do
      status, _headers, body = call("/api/sessions/#{session.id}/images?name=o.png", method: "POST", body: png, token: owner_token)
      expect(status).to eq(201)
      expect(JSON.parse(body)).to include("source" => "user", "mime" => "image/png")
      expect(File.exist?(File.join(dir, Samagotchi::ParticipantUploads::FILE))).to be(false)
    end
  end
end
