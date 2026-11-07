# frozen_string_literal: true

require "json"
require "samagotchi/redact"
require "samagotchi/web/link_codes"
require "samagotchi/web/participant_view"

# What a participant gets of every string (secret shapes, the owner's token,
# the session's folder and home): Web::ParticipantView's defence in depth,
# and how the Engine reads a Verify quote.
RSpec.describe Samagotchi::Redact do
  let(:viewer) { described_class::Viewer.new(author: "p:p_1", cwd: "/home/o/proj", home: "/home/o", secrets: ["OWNERTOKEN123"]) }

  it "takes the likeliest quoted secret shapes: env names, JSON keys, URL passwords, JWTs, Google and Stripe keys" do
    text = "OPENAI_API_KEY=abc123 DATABASE_PASSWORD=hunter2 AWS_SECRET_ACCESS_KEY=xyz {\"api_key\": \"k1\"} ?access_token=t1&x=1 " \
           "postgres://app:pa55@db/x eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT AIzaSyA1234567890abcdefghijklmnopqrstu rk_live_abcdefghijklmnop1234"
    out = described_class.text(text, viewer)
    %w[abc123 hunter2 xyz k1 t1 pa55 eyJzdWIi AIzaSy rk_live].each { |leak| expect(out).not_to include(leak), leak }
    expect(out).to include("postgres://app:[redacted]@db/x", "&x=1")
  end

  it "takes secret shapes, the owner's token, the session's folder and home out of every string" do
    text = "key sk-ant-abcdefghijklmnopqrstu ghp_abcdefghijklmnopqrstuvwxyz0123 AKIAABCDEFGHIJKLMNOP xoxb-1234567890-abc " \
           "chp_abcdefghijklmnopqrstuvwxyz Authorization: Bearer abc.def token=zzz OWNERTOKEN123 at /home/o/proj/a.rb in /home/o/proj, /home/o/notes " \
           "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY----- /home/oscar stays"
    out = described_class.text(text, viewer)
    expect(out).not_to include("sk-ant", "ghp_", "AKIA", "xoxb", "chp_", "abc.def", "zzz", "OWNERTOKEN", "MIIE", "/home/o/")
    expect(described_class.text("`API_KEY=sk-ant-abcdefghijklmnopqrstu` here", viewer)).to eq("`API_KEY=[redacted]` here")
    expect(out).to include("Authorization: Bearer [redacted]", "token=[redacted]", "at a.rb in ., ~/notes", "/home/oscar stays")
  end

  # The cases claim_link.js reads the same (its normalizeClaim mirrors these patterns).
  it "reads the shared redact cases (spec/fixtures/redact_cases.json) as the claim link does" do
    cases = JSON.parse(File.read(File.expand_path("fixtures/redact_cases.json", __dir__)))
    shared = described_class::Viewer.new(cwd: cases["cwd"], home: cases["home"])
    cases["cases"].each { |input, output| expect(described_class.text(input, shared)).to eq(output), input }
  end

  it "takes a one-time link code (chc_, a bearer credential) and a Bridge's secret header out, in a reply too" do
    code = "chc_#{"aB3-_" * 8}xyz"
    text = "Send Bob https://pod/#code=#{code}&s=abc, and curl -H 'X-Chi-Bridge: 0123456789abcdef0123' there"
    out = described_class.text(text, viewer)
    expect(out).to eq("Send Bob https://pod/#code=[redacted]&s=abc, and curl -H 'X-Chi-Bridge: [redacted]' there")
    expect(Samagotchi::Web::ParticipantView.reply("Bob's link: https://pod/#code=#{code}&s=abc", viewer))
      .to eq("Bob's link: https://pod/#code=[redacted]&s=abc")
    expect(Samagotchi::Web::LinkCodes.code?(code)).to be(true)
  end
end
