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

  it "asks nothing without history, without a change, or at a cheap cost" do
    expect(described_class.ask(line: "/thinking low", cost: :full, changed: true, engine: cache_engine(history: false))).to be_nil
    expect(described_class.ask(line: "/thinking low", cost: :full, changed: false, engine: cache_engine)).to be_nil
    expect(described_class.ask(line: "/thinking low", cost: :tail, changed: true, engine: cache_engine)).to be_nil
  end

  it "asks with the full-conversation size for full and provider costs" do
    %i[full provider].each do |cost|
      confirm = described_class.ask(line: "/model X --default --alias N", cost: cost, changed: true,
                                    engine: cache_engine)

      expect(confirm.line).to eq("/model X --default --alias N --yes")
      expect(confirm.text).to include("The next request reads the whole conversation again (about 104k tokens).")
      expect(confirm.text).to end_with("Nothing changed yet: send `/model X --default --alias N --yes` to apply.")
    end
  end

  it "names the changed-reply size for history costs" do
    confirm = described_class.ask(line: "/reasoning-history all", cost: :history, changed: true,
                                  engine: cache_engine(tokens: 8_200))

    expect(confirm.text).to include("The next request reads again from the first changed reply (up to about 8.2k tokens).")
  end

  it "leaves out the size when the engine has no token count" do
    confirm = described_class.ask(line: "/thinking low", cost: :full, changed: true,
                                  engine: cache_engine(tokens: nil))

    expect(confirm.text).not_to include("tokens")
    expect(confirm.text).to eq("Nothing changed yet: send `/thinking low --yes` to apply.")
  end

  it "notes preserved thinking on Anthropic full-prefix changes" do
    confirm = described_class.ask(line: "/thinking low", cost: :full, changed: true,
                                  engine: cache_engine(api: :anthropic))

    expect(confirm.text).to include("On an `api: anthropic` host, preserved thinking in replies is dropped from then on.")
  end

  it "does not note preserved thinking for history-only changes" do
    confirm = described_class.ask(line: "/reasoning-history all", cost: :history, changed: true,
                                  engine: cache_engine(api: :anthropic))

    expect(confirm.text).not_to include("preserved thinking")
  end

  def cache_engine(tokens: 104_000, api: :openai, history: true)
    double(history?: history, cache_restart_tokens: tokens, cache_restart_anthropic?: api.to_s == "anthropic")
  end
end
