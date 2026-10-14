# frozen_string_literal: true

require "spec_helper"
require "samagotchi/peer_sources"

RSpec.describe Samagotchi::PeerSources do
  let(:sources) { described_class.new }

  it "keeps a declared source's peer name, and nothing for another" do
    sources.declare("codex-outbox", label: "Codex", bundle: "codex-peer")

    expect(sources.label_for("codex-outbox")).to eq("Codex")
    expect(sources.label_for("ci")).to be_nil
    expect(sources.names).to eq(["codex-outbox"])
  end

  it "refuses a bad name, a label that isn't a short name, and a name another bundle declared" do
    expect { sources.check!("Bad Name", label: "Codex", bundle: "b") }.to raise_error(ArgumentError, /peer source/)
    expect { sources.check!("x", label: "codex", bundle: "b") }.to raise_error(ArgumentError, /label must match/)
    expect { sources.check!("x", label: "A #{"b" * 30}", bundle: "b") }.to raise_error(ArgumentError, /label/)
    sources.declare("codex-outbox", label: "Codex", bundle: "codex-peer")
    expect { sources.declare("codex-outbox", label: "Other", bundle: "other") }
      .to raise_error(ArgumentError, "peer source codex-outbox is already declared (codex-peer)")
    expect(sources.label_for("codex-outbox")).to eq("Codex")
  end
end
