# frozen_string_literal: true

require "samagotchi/text_diff"

RSpec.describe Samagotchi::TextDiff do
  def diff(before, after, **opts) = described_class.unified(before, after, **opts)

  # CPU seconds this thread spent in the block: unlike the wall clock, not
  # stretched by other processes (parallel_rspec, a busy CI runner).
  # Benchmark is not a default gem from Ruby 4.0.
  def elapsed
    start = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
    yield
    Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - start
  end

  def numbered(range) = range.map { |i| "line #{i}\n" }.join

  it "shows one changed line with three lines of context" do
    before = numbered(1..10)
    after = before.sub("line 5\n", "line five\n")
    expect(diff(before, after)).to eq(
      text: "@@ -2,7 +2,7 @@\n line 2\n line 3\n line 4\n-line 5\n+line five\n line 6\n line 7\n line 8",
      added: 1, removed: 1, truncated: false
    )
  end

  it "keeps changes close together in one hunk and far apart in two" do
    before = numbered(1..30)
    close = before.sub("line 5\n", "x\n").sub("line 11\n", "y\n")
    far = before.sub("line 5\n", "x\n").sub("line 20\n", "y\n")
    expect(diff(before, close)[:text].scan(/^@@/).size).to eq(1)
    expect(diff(before, far)[:text].scan(/^@@.*@@$/)).to eq(["@@ -2,7 +2,7 @@", "@@ -17,7 +17,7 @@"])
  end

  it "writes insertions and deletions with diff -u line numbers" do
    before = numbered(1..6)
    expect(diff(before, before.sub("line 3\n", ""))[:text]).to start_with("@@ -1,6 +1,5 @@")
    expect(diff(before, before.sub("line 3\n", "line 3\nnew\n"))[:text]).to start_with("@@ -1,6 +1,7 @@")
  end

  it "finds a minimal diff in a shuffled middle" do
    before = "a\nb\nc\nd\ne\nf\ng\n"
    after = "a\nc\nb\nd\nx\nf\ng\n"
    result = diff(before, after)
    expect([result[:added], result[:removed]]).to eq([2, 2])
  end

  it "treats an empty before as a new file" do
    expect(diff("", "a\nb\n")).to eq(text: "@@ -0,0 +1,2 @@\n+a\n+b", added: 2, removed: 0, truncated: false)
    expect(diff("a\n", "")[:text]).to eq("@@ -1 +0,0 @@\n-a")
  end

  it "returns no hunks for identical input" do
    expect(diff("same\n", "same\n")).to eq(text: "", added: 0, removed: 0, truncated: false)
    expect(diff("", "")).to eq(text: "", added: 0, removed: 0, truncated: false)
  end

  it "marks a missing newline at end of file like diff -u" do
    expect(diff("a\nb", "a\nc")[:text]).to eq(
      "@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+c\n\\ No newline at end of file"
    )
    expect(diff("a\n", "a")[:text]).to eq("@@ -1 +1 @@\n-a\n+a\n\\ No newline at end of file")
  end

  it "keeps CRLF line endings as they are" do
    expect(diff("a\r\nb\r\n", "a\r\nc\r\n")[:text]).to eq("@@ -1,2 +1,2 @@\n a\r\n-b\r\n+c\r")
  end

  it "scrubs invalid UTF-8 so the text can go into JSON" do
    text = diff("ok\n", "bad \xFF\n".b)[:text]
    expect(text).to be_valid_encoding
    expect(text).to include("+bad �")
  end

  it "cuts the text at max_lines and keeps the counts exact" do
    result = diff("", numbered(1..300))
    lines = result[:text].lines
    expect(lines.size).to eq(121) # the header + 119 lines + the note
    expect(lines.last).to eq("… 181 more lines")
    expect(result).to include(added: 300, removed: 0, truncated: true)
  end

  it "cuts the text at max_bytes" do
    result = diff("", Array.new(40) { "#{"x" * 400}\n" }.join)
    expect(result[:text].bytesize).to be <= described_class::MAX_BYTES + 40
    expect(result[:text]).to end_with("more lines")
    expect(result[:truncated]).to be true
  end

  it "falls back to all removed / all added past the edit distance cap, still correct" do
    stub_const("#{described_class}::MAX_EDIT_DISTANCE", 3)
    before = "keep\n#{numbered(1..10)}end\n"
    after = before.lines.each_with_index.map { |l, i| i.odd? && i < 11 ? "changed #{i}\n" : l }.join
    result = diff(before, after, max_lines: 1000)
    expect(result[:text]).to match(/\A@@ -1,12 \+1,12 @@\n keep\n(-line \d+\n){9}(\+.*\n){9} line 10\n end\z/)
  end

  it "diffs a 5 000-line rewrite and a dense 5 000-line edit in well under two CPU seconds" do
    before = numbered(1..5000)
    rewrite = (1..5000).map { |i| "other #{i}\n" }.join
    dense = before.lines.each_with_index.map { |l, i| (i % 3).zero? ? "x#{i}\n" : l }.join
    expect(elapsed { diff(before, rewrite) }).to be < 0.5
    expect(elapsed { diff(before, dense) }).to be < 1.5 # ~0.25 s on a laptop
  end

  it "rebuilds the after text from its edit script (random edits)" do
    rng = Random.new(7)
    50.times do
      a = Array.new(rng.rand(30)) { "l#{rng.rand(6)}\n" }
      b = a.map { |l| rng.rand < 0.3 ? "m#{rng.rand(6)}\n" : l }
      b.insert(rng.rand(b.size + 1), "ins\n")
      ops = described_class.edit_script(a, b)
      expect(ops.filter_map { |t, i, j| t == :add ? b[j] : (a[i] if t == :eq) }).to eq(b)
      expect(ops.filter_map { |t, i, _| a[i] unless t == :add }).to eq(a)
    end
  end
end
