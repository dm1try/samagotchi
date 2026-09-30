# frozen_string_literal: true

require "stringio"
require "samagotchi/terminal_ui/plain_surface"

RSpec.describe Samagotchi::TerminalUI::PlainSurface do
  let(:out) { StringIO.new }
  let(:surface) { described_class.new(out: out) }

  it "prints committed text and the rows below the prompt as plain lines" do
    surface.commit("hello")
    surface.set_slot(:notes, ["? Which one?", "  1) Apple"])

    expect(out.string).to eq("hello\n? Which one?\n  1) Apple\n")
    expect(out.string).not_to include("\e[")
  end

  it "prints fitted content once, at its width with no height limit" do
    content = Struct.new(:fits) do
      def fit(width:, height:)
        fits << [width, height]
        ["? pick", "1) Apple"]
      end
    end.new([])
    allow(surface).to receive(:columns).and_return(50)
    surface.set_slot(:notes, content)

    expect(out.string).to eq("? pick\n1) Apple\n")
    expect(content.fits).to eq([[50, nil]])
  end

  it "drops the activity slot, which only a live region can redraw in place" do
    surface.set_slot(:activity, ["| thinking…"])
    surface.set_slot(:activity, ["/ thinking…"])

    expect(out.string).to be_empty
    expect(surface.clear_slot(:activity)).to be(false)
  end

  it "has nothing to erase, and prints a plain read's prompt with no newline" do
    expect(surface.clear_slot(:editor)).to be(false)
    surface.set_slot(:editor, ["? "])

    expect(out.string).to eq("? ")
    expect { surface.set_slot(:banner, ["x"]) }.to raise_error(ArgumentError, /unknown slot/)
  end

  it "writes to $stdout as it is at each write when given no output" do
    surface = described_class.new
    swapped = StringIO.new
    original = $stdout
    $stdout = swapped
    surface.commit("hello")

    expect(swapped.string).to eq("hello\n")
  ensure
    $stdout = original
  end
end
