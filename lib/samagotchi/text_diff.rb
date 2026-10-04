# frozen_string_literal: true

module Samagotchi
  # Line-based unified diff (like `diff -u` without the file header), used to
  # show what chi's edit/write tools change. Pure: strings in, a hash out.
  #
  #   TextDiff.unified("a\nb\n", "a\nc\n")
  #   # => {text: "@@ -1,2 +1,2 @@\n a\n-b\n+c", added: 1, removed: 1, truncated: false}
  #
  # The common prefix and suffix are trimmed first (edits are local), then
  # Myers O(ND) runs on the middle. When the edit distance passes
  # MAX_EDIT_DISTANCE it gives up on a minimal diff and shows the whole middle
  # as removed then added: correct, just not minimal. The text is cut at
  # MAX_LINES / MAX_BYTES with a "… N more lines" line; the counts stay exact.
  module TextDiff
    CONTEXT = 3
    MAX_LINES = 120
    MAX_BYTES = 8 * 1024
    MAX_EDIT_DISTANCE = 1000 # D² work: ~0.35 s for a dense 5 000-line edit
    NO_NEWLINE = "\\ No newline at end of file"

    module_function

    def unified(before, after, context: CONTEXT, max_lines: MAX_LINES, max_bytes: MAX_BYTES)
      a = clean(before).lines
      b = clean(after).lines
      ops = edit_script(a, b)
      added = ops.count { |op| op[0] == :add }
      removed = ops.count { |op| op[0] == :del }
      text, truncated = render(hunks(ops, context), a, b, max_lines, max_bytes)
      { text: text, added: added, removed: removed, truncated: truncated }
    end

    def clean(text)
      text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("�")
    end

    # Ops are [:eq, ai, bi], [:del, ai, nil] or [:add, nil, bi] in file order.
    def edit_script(a, b)
      pre = 0
      pre += 1 while pre < a.size && pre < b.size && a[pre] == b[pre]
      suf = 0
      suf += 1 while suf < a.size - pre && suf < b.size - pre && a[-1 - suf] == b[-1 - suf]

      ops = (0...pre).map { |i| [:eq, i, i] }
      a_mid = a[pre...(a.size - suf)]
      b_mid = b[pre...(b.size - suf)]
      middle = myers(a_mid, b_mid) ||
               a_mid.each_index.map { |i| [:del, i, nil] } + b_mid.each_index.map { |j| [:add, nil, j] }
      middle.each { |t, i, j| ops << [t, i && i + pre, j && j + pre] }
      (0...suf).each { |s| ops << [:eq, a.size - suf + s, b.size - suf + s] }
      ops
    end

    # Myers' greedy forward search, keeping one slice of V per round for the
    # backtrack. Returns nil when the edit distance passes max_d.
    def myers(a, b, max_d = MAX_EDIT_DISTANCE)
      ids = {}
      a = a.map { |l| ids[l] ||= ids.size }
      b = b.map { |l| ids[l] ||= ids.size }
      # No line in common (a full rewrite): the fallback is the minimal diff.
      return nil if ids.size == a.uniq.size + b.uniq.size

      n = a.size
      m = b.size
      off = n + m + 1
      v = Array.new(2 * off + 1, 0)
      trace = []
      (0..(n + m)).each do |d|
        return nil if d > max_d

        # Round d reads k-1 and k+1 for k in -d..d: keep -(d+1)..d+1.
        trace << v[off - d - 1, 2 * d + 3]
        k = -d
        while k <= d
          x = if k == -d || (k != d && v[off + k - 1] < v[off + k + 1])
                v[off + k + 1]
              else
                v[off + k - 1] + 1
              end
          y = x - k
          while x < n && y < m && a[x] == b[y]
            x += 1
            y += 1
          end
          v[off + k] = x
          return backtrack(trace, n, m) if x >= n && y >= m

          k += 2
        end
      end
      []
    end

    def backtrack(trace, x, y)
      ops = []
      (trace.size - 1).downto(0) do |d|
        vd = trace[d]
        at = ->(k) { vd[k + d + 1] }
        k = x - y
        prev_k = k == -d || (k != d && at.call(k - 1) < at.call(k + 1)) ? k + 1 : k - 1
        prev_x = at.call(prev_k)
        prev_y = prev_x - prev_k
        while x > prev_x && y > prev_y
          x -= 1
          y -= 1
          ops << [:eq, x, y]
        end
        break if d.zero?

        ops << if x == prev_x
                 [:add, nil, prev_y]
               else
                 [:del, prev_x, nil]
               end
        x = prev_x
        y = prev_y
      end
      ops.reverse
    end

    # Groups ops into hunks: runs of changes whose gaps are at most 2*context
    # unchanged lines, each padded with up to context lines on both sides.
    def hunks(ops, context)
      changed = ops.each_index.reject { |i| ops[i][0] == :eq }
      return [] if changed.empty?

      groups = [[changed.first, changed.first]]
      changed.drop(1).each do |i|
        if i - groups.last[1] - 1 <= 2 * context
          groups.last[1] = i
        else
          groups << [i, i]
        end
      end
      groups.map { |first, last| ops[[first - context, 0].max..[last + context, ops.size - 1].min] }
    end

    def render(hunks, a, b, max_lines, max_bytes)
      lines = []
      hunks.each do |hunk|
        lines << header(hunk)
        hunk.each do |t, i, j|
          line = t == :add ? b[j] : a[i]
          mark = { eq: " ", del: "-", add: "+" }[t]
          # Only the "\n": chomp("\n") would take a CRLF's "\r" too.
          lines << mark + (line.end_with?("\n") ? line[0...-1] : line)
          lines << NO_NEWLINE unless line.end_with?("\n")
        end
      end
      cut(lines, max_lines, max_bytes)
    end

    # @@ -start,len +start,len @@ with diff -u's conventions: ",1" is left
    # out. A side with no lines in the hunk is an empty file (any other hunk
    # has context lines), shown as 0,0.
    def header(hunk)
      a_lines = hunk.filter_map { |t, i, _| i unless t == :add }
      b_lines = hunk.filter_map { |t, _, j| j unless t == :del }
      "@@ -#{range(a_lines)} +#{range(b_lines)} @@"
    end

    def range(indexes)
      return "0,0" if indexes.empty?

      indexes.size == 1 ? (indexes.first + 1).to_s : "#{indexes.first + 1},#{indexes.size}"
    end

    def cut(lines, max_lines, max_bytes)
      bytes = 0
      lines.each_with_index do |line, i|
        bytes += line.bytesize + 1
        next unless i >= max_lines || bytes > max_bytes

        rest = lines.size - i
        return [(lines[0, i] + ["… #{rest} more lines"]).join("\n"), true]
      end
      [lines.join("\n"), false]
    end
  end
end
