# frozen_string_literal: true

require "spec_helper"
require "digest"
require "yaml"
require "samagotchi/testing/rspec"

# spec/fixtures/sign_in_echo_bundle: ctx.sign_in's and ctx.secrets' first
# caller, the bundle docs/plugins.md ("Sign-in") shows whole, tested on the
# kit's sign-ins (no port opened) and its in-memory secrets.
RSpec.describe "The sign-in-echo bundle", :bundle do
  let(:dir) { File.expand_path("../../fixtures/sign_in_echo_bundle", __dir__) }
  let(:bundle) { load_bundle(dir) }

  def signed_in_card = bundle.cards.find { |card| card[:title] == "Signed in to Echo" }

  it "shows a card whose button opens the provider with the redirect and a state" do
    expect(bundle.command("/echo-login")).to be_nil
    flow = bundle.sign_ins.last
    expect(flow.title).to eq("Sign in to Echo")
    query = URI.decode_www_form(URI(flow.address).query).to_h
    expect(flow.address).to start_with("http://127.0.0.1:9100/authorize?")
    expect(query["redirect_uri"]).to eq(flow.redirect_uri)
    expect(query["state"]).to match(/\A\h{32}\z/)
    expect(bundle.cards.last).to include(id: flow.card_id, title: "Sign in to Echo",
                                         actions: [{ label: "Open sign-in page", url: flow.address }])
  end

  it "keeps the callback's code as a secret and replaces the card; echo_token reads it back" do
    bundle.command("/echo-login")
    state = URI.decode_www_form(URI(bundle.sign_ins.last.address).query).to_h["state"]
    expect(bundle.complete_sign_in("code" => "C1", "state" => "wrong")).to be(false)
    expect(bundle.complete_sign_in("code" => "C1", "state" => state)).to be(true)

    wait_for("the bundle's thread to keep the code") { bundle.secrets["echo"] }
    expect(bundle.secrets).to eq("echo" => "C1")
    wait_for("the card to say signed in") { signed_in_card }
    expect(signed_in_card[:id]).to eq(bundle.sign_ins.last.card_id)
    expect(bundle.tool("echo_token")).to eq("signed in: C1")
  end

  it "keeps nothing when the sign-in times out: chi's card says so" do
    bundle.set(secrets: { "echo" => "OLD" })
    bundle.command("/echo-login")
    bundle.fail_sign_in(:timed_out)
    expect(bundle.cards.last).to include(title: "Sign-in timed out", actions: [])
    expect(bundle.secrets).to eq("echo" => "OLD")
    expect(bundle.tool("echo_token")).to eq("signed in: OLD")
  end

  it "says sign-in needs a UI in a one-shot run" do
    bundle.set(frontend: :non_interactive)
    expect(bundle.command("/echo-login")).to eq("sign-in needs the web or a terminal")
    expect(bundle.sign_ins).to eq([])
    expect(bundle.tool("echo_token")).to eq("not signed in (run /echo-login)")
  end

  it "is the code docs/plugins.md shows, and its manifest sha256 is current" do
    docs = File.read(File.expand_path("../../../docs/plugins.md", __dir__))
    shown = docs[/^### A whole bundle: sign-in-echo.*?^```ruby\n(.*?)^```$/m, 1]
    expect(shown).to eq(File.read(File.join(dir, "plugin.rb")))

    manifest = YAML.safe_load_file(File.join(dir, "manifest.yml"))
    expect(manifest.dig("plugin", "sha256")).to eq("sha256:#{Digest::SHA256.file(File.join(dir, "plugin.rb")).hexdigest}")
  end
end
