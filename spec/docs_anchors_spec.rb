# frozen_string_literal: true

require "pathname"

# Every relative Markdown link with an anchor in docs/ and AGENTS.md
# (`file.md#anchor`, or `#anchor` into the same file) names a heading of
# its target, slugged as GitHub does: the rendered heading text, lowercased,
# every character but a letter, a digit, `_`, `-` and a space dropped, each
# space a `-`, and a repeated slug numbered (`-1`, `-2`). Dead anchors had
# survived two audit rounds by hand.
RSpec.describe "docs/ anchor links" do
  root = Pathname.new(File.expand_path("..", __dir__))
  sources = [root.join("AGENTS.md"), *Pathname.glob(root.join("docs/**/*.md"))]

  # The text with its fenced blocks blanked out (line numbers kept). A
  # backtick run whose info string holds a backtick is a code span, not a
  # fence (```` ``` ```` at a line's start); a fence closes on a bare run
  # of its own character at least as long.
  unfenced = lambda do |text|
    fence = nil
    text.lines.map do |line|
      mark, info = line.match(/^\s*(`{3,}|~{3,})(.*)$/)&.captures
      mark = nil if mark&.start_with?("`") && info.include?("`")
      if mark && fence.nil?
        fence = mark
      elsif mark && mark[0] == fence[0] && mark.size >= fence.size && info.strip.empty?
        fence = nil
      elsif fence.nil?
        next line
      end
      "\n"
    end
  end

  slug = lambda do |heading|
    text = heading.gsub(/\[([^\]]*)\]\([^)]*\)/, '\1').gsub(/<[^>]+>/, "")
    text.downcase.gsub(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/, "").tr(" ", "-")
  end

  anchors_of = Hash.new do |memo, path|
    seen = Hash.new(0)
    memo[path] = unfenced.call(path.read).filter_map do |line|
      if (heading = line[/^\#{1,6}\s+(.*?)\s*#*\s*$/, 1])
        base = slug.call(heading)
        count = seen[base]
        seen[base] += 1
        count.zero? ? base : "#{base}-#{count}"
      elsif (id = line[/<a\s+(?:id|name)="([^"]+)"/, 1])
        id
      end
    end
  end

  dead = sources.flat_map do |source|
    unfenced.call(source.read).each_with_index.flat_map do |line, index|
      line.gsub(/`[^`]*`/, "").scan(/\]\(([^)\s]*)#([^)\s]+)\)/).filter_map do |file, anchor|
        next if file.match?(%r{\A[a-z]+://}i)

        target = file.empty? ? source : source.dirname.join(file).cleanpath
        next unless target.extname == ".md" && target.file?
        next if anchors_of[target].include?(anchor)

        "#{source.relative_path_from(root)}:#{index + 1}: #{file}##{anchor}"
      end
    end
  end

  it "reads the links of AGENTS.md and every docs/ page" do
    expect(sources.size).to be > 10
    expect(anchors_of[root.join("docs/guardrails.md")]).to include("system-1-experimental")
  end

  it "resolves every relative anchor to a heading of its target" do
    expect(dead).to eq([])
  end
end
