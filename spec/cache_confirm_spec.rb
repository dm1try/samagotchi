# frozen_string_literal: true

require_relative "../lib/samagotchi/cache_confirm"

RSpec.describe Samagotchi::CacheConfirm do
  it "takes --yes or -y out from anywhere, and says whether it was there" do
    expect(described_class.split(" LOW --yes ")).to eq(["low", true])
    expect(described_class.split("-y all")).to eq(["all", true])
    expect(described_class.split("all")).to eq(["all", false])
    expect(described_class.split("  ")).to eq(["", false])
    expect(described_class.split(nil)).to eq(["", false])
  end

  it "asks only for a costly change of the effective level once the session has a reply" do
    expect(%i[full provider history].map { |cost| described_class.needed?(cost: cost, history: true, changed: true) })
      .to all(be(true))
    expect(described_class.needed?(cost: :tail, history: true, changed: true)).to be(false)
    expect(described_class.needed?(cost: nil, history: true, changed: true)).to be(false)
    expect(described_class.needed?(cost: :full, history: false, changed: true)).to be(false)
    expect(described_class.needed?(cost: :full, history: true, changed: false)).to be(false)
  end

  it "names the line that applies it" do
    confirm = described_class.confirm("/reasoning-history", "all")
    expect(confirm.to_h).to eq(line: "/reasoning-history all --yes",
                               text: "Nothing changed yet: send `/reasoning-history all --yes` to apply.")
  end
end
