# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plugin/card"

# Plugin::Card.build: the checked card event Engine#show_card routes (its
# routing: cards_spec.rb).
RSpec.describe Samagotchi::Plugin::Card do
  def build(**overrides)
    described_class.build(source: "b", title: " T ", body: nil, actions: [], level: :info, id: nil, **overrides)
  end

  it "normalizes the card and gives it an id when none is given" do
    card = build(actions: [{ "label" => " ", "command" => "/x go" }], level: "warn")
    expect(card).to include(type: :card, source: "b", title: "T", body: "", level: :warn,
                            actions: [{ label: "/x go", command: "/x go" }])
    expect(card[:id]).to match(/\A\h{8}\z/)
    expect(build(id: " c1 ")[:id]).to eq("c1")
  end

  it "refuses a card without a title, a bad level, too many or bad actions" do
    expect { build(title: " ") }.to raise_error(ArgumentError, "a card needs a title")
    expect { build(level: :error) }.to raise_error(ArgumentError, /card level must be one of info, warn/)
    expect { build(actions: Array.new(7) { { command: "/x" } }) }.to raise_error(ArgumentError, /at most 6 actions/)
    expect { build(actions: ["/x"]) }.to raise_error(ArgumentError, /is a Hash/)
    expect { build(actions: [{ command: "/x\n/y" }]) }.to raise_error(ArgumentError, /needs a command/)
  end
end
