# frozen_string_literal: true

require "spec_helper"
require "samagotchi/web/push/crypto"
require_relative "../../support/web_push_receiver"

RSpec.describe Samagotchi::Web::Push::Crypto do
  def u(text) = described_class.unb64u(text)

  # RFC 8291 Appendix A: the example message, its keys and salt.
  describe ".encrypt" do
    let(:sender) do
      described_class.ec_private(u("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"),
                                 u("BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"))
    end
    let(:ua_public) { u("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4") }
    let(:auth) { u("BTBZMqHH6r4Tts7J_aSIgg") }
    let(:plaintext) { "When I grow up, I want to be a watermelon" }

    it "gives RFC 8291 Appendix A's body byte for byte" do
      body = described_class.encrypt(plaintext, p256dh: ua_public, auth: auth, salt: u("DGv6ra1nlYgDCS1FRnbzlw"),
                                                sender_key: sender)

      expect(described_class.b64u(body)).to eq(
        "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_" \
        "yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
      )
    end

    it "decrypts with the receiver's key (the RFC's receiver, and a fresh one)" do
      rfc_receiver = WebPushReceiver.new(key: described_class.ec_private(u("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"), ua_public),
                                         auth: auth)
      expect(rfc_receiver.decrypt(described_class.encrypt(plaintext, p256dh: ua_public, auth: auth))).to eq(plaintext.b)

      fresh = WebPushReceiver.new
      body = described_class.encrypt("{\"v\":1} ✓", p256dh: fresh.p256dh, auth: fresh.auth)
      expect(fresh.decrypt(body).force_encoding("UTF-8")).to eq("{\"v\":1} ✓")
    end
  end

  describe ".vapid_authorization" do
    let(:key) { described_class.generate_key }
    let(:now) { Time.at(1_800_000_000) }

    it "is an ES256 JWT that verifies with k= and carries aud (the endpoint's origin), exp and sub" do
      header = described_class.vapid_authorization("https://web.push.apple.com/QGxyz?a=1", key: key,
                                                                                            sub: "https://studio.example.ts.net", now: now)

      expect(header).to match(/\Avapid t=[\w-]+\.[\w-]+\.[\w-]+, k=[\w-]+\z/)
      expect(header[/k=(\S+)\z/, 1]).to eq(described_class.public_key_b64(key))
      expect(WebPushReceiver.vapid_claims(header)).to eq("aud" => "https://web.push.apple.com",
                                                         "exp" => now.to_i + (12 * 3600), "sub" => "https://studio.example.ts.net")
      expect(JSON.parse(u(header[/t=([\w-]+)\./, 1]))).to eq("typ" => "JWT", "alg" => "ES256")
    end

    it "keeps a port that isn't the scheme's in aud" do
      header = described_class.vapid_authorization("http://127.0.0.1:9999/push/x", key: key, sub: "mailto:a@b.c", now: now)
      expect(WebPushReceiver.vapid_claims(header)["aud"]).to eq("http://127.0.0.1:9999")
    end

    it "doesn't verify with another key" do
      header = described_class.vapid_authorization("https://web.push.apple.com/x", key: key, sub: "mailto:a@b.c", now: now)
      other = described_class.public_key_b64(described_class.generate_key)
      expect(WebPushReceiver.vapid_claims(header.sub(/k=\S+\z/, "k=#{other}"))).to be_nil
    end
  end

  describe ".public_key_b64" do
    it "is the 65-byte uncompressed point, base64url without padding" do
      raw = u(described_class.public_key_b64(described_class.generate_key))
      expect(raw.bytesize).to eq(65)
      expect(raw.getbyte(0)).to eq(4)
    end
  end

  describe ".valid_sub?" do
    it "takes a mailto: with an @ and an https URL with a host" do
      expect(described_class.valid_sub?("mailto:chi@example.com")).to be(true)
      expect(described_class.valid_sub?("https://studio.tailfd09db.ts.net")).to be(true)
    end

    it "refuses what Apple answers 403 BadJwtToken for, and other near misses" do
      expect(described_class.valid_sub?("chi@localhost")).to be(false)
      expect(described_class.valid_sub?("mailto:nobody")).to be(false)
      expect(described_class.valid_sub?("http://studio.example")).to be(false)
      expect(described_class.valid_sub?("https://")).to be(false)
      expect(described_class.valid_sub?(nil)).to be(false)
    end
  end

  describe ".unb64u" do
    it "takes padded and unpadded text and refuses what isn't base64url" do
      expect(described_class.unb64u("YQ")).to eq("a")
      expect(described_class.unb64u("YQ==")).to eq("a")
      expect { described_class.unb64u("a+b/") }.to raise_error(ArgumentError)
    end
  end
end
