# frozen_string_literal: true

require "stringio"
require "samagotchi/terminal_ui/legacy_surface"

# LegacySurface writes the bytes the REPL wrote before the Surface seam
# existed; these pin them (the goldens pin them end to end).
RSpec.describe Samagotchi::TerminalUI::LegacySurface do
  let(:out) { StringIO.new }
  let(:surface) { described_class.new(out: out) }

  def written
    text = out.string.dup
    out.truncate(0)
    out.rewind
    text
  end

  describe "#commit" do
    it "prints the text as a line, like puts" do
      surface.commit("tool> read")
      surface.commit("\nmodel> nothing to continue")
      surface.commit("ends in a newline\n")
      surface.commit("")
      surface.commit(nil)

      expect(written).to eq("tool> read\n\nmodel> nothing to continue\nends in a newline\n\n\n")
    end
  end

  describe "the activity slot" do
    it "redraws in place: back up over the rows drawn last, pad to the taller height" do
      surface.set_slot(:activity, %w[a b])
      expect(written).to eq("a\e[0K\nb\e[0K")

      surface.set_slot(:activity, %w[c d e])
      expect(written).to eq("\e[1A\rc\e[0K\nd\e[0K\ne\e[0K")

      surface.set_slot(:activity, %w[f])
      expect(written).to eq("\e[2A\rf\e[0K\n\e[0K\n\e[0K")
    end

    it "moves back to the start of a single row before redrawing it" do
      surface.set_slot(:activity, %w[a])
      written

      surface.set_slot(:activity, %w[b])

      expect(written).to eq("\rb\e[0K")
    end

    it "erases every row it drew and returns to the first, once" do
      surface.set_slot(:activity, %w[a b c])
      written

      expect(surface.clear_slot(:activity)).to be(true)
      expect(written).to eq("\e[2A\r\e[0K\n\e[0K\n\e[0K\e[2A\r")

      expect(surface.clear_slot(:activity)).to be(false)
      expect(written).to eq("")
    end

    it "erases a single row without moving up" do
      surface.set_slot(:activity, %w[a])
      written

      surface.clear_slot(:activity)

      expect(written).to eq("\r\e[0K\r")
    end

    it "starts afresh after a clear" do
      surface.set_slot(:activity, %w[a b])
      surface.clear_slot(:activity)
      written

      surface.set_slot(:activity, %w[c])

      expect(written).to eq("c\e[0K")
    end
  end

  describe "#set_slots" do
    it "draws the status rows as the activity block's last rows, as one redraw" do
      surface.set_slots(activity: ["| thinking"], status: ["status> model=x"])
      surface.set_slots(activity: ["/ thinking"], status: ["status> model=x"])

      expect(written).to eq("| thinking\e[0K\nstatus> model=x\e[0K\e[1A\r/ thinking\e[0K\nstatus> model=x\e[0K")
      expect(surface.clear_slot(:activity)).to be(true)
      expect(written).to eq("\e[1A\r\e[0K\n\e[0K\e[1A\r")
    end

    it "prints the status rows as lines without an activity block" do
      surface.set_slots(status: ["status> model=x"])

      expect(written).to eq("status> model=x\n")
    end
  end

  describe "the editor slot" do
    it "prints a plain prompt without a newline, and erases the line Reline drew" do
      surface.set_slot(:editor, ["choice> "])
      expect(written).to eq("choice> ")

      expect(surface.clear_slot(:editor)).to be(true)
      expect(written).to eq("\r\e[2K")
    end
  end

  describe "the other slots" do
    it "prints their rows as lines, and has nothing to erase" do
      surface.set_slot(:status, ["status> model=x"])
      surface.set_slot(:notes, ["? Which one?", "  1) Apple"])

      expect(written).to eq("status> model=x\n? Which one?\n  1) Apple\n")
      expect(surface.clear_slot(:notes)).to be(false)
      expect(written).to eq("")
    end
  end

  it "rejects an unknown slot" do
    expect { surface.set_slot(:banner, ["x"]) }.to raise_error(ArgumentError, /unknown slot :banner/)
    expect { surface.clear_slot(:banner) }.to raise_error(ArgumentError, /unknown slot :banner/)
  end

  it "writes to $stdout as it is at the time of the write" do
    surface = described_class.new
    swapped = StringIO.new
    original = $stdout
    $stdout = swapped
    begin
      surface.commit("late")
    ensure
      $stdout = original
    end

    expect(swapped.string).to eq("late\n")
  end
end
