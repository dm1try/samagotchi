# frozen_string_literal: true

# An after_turn hook that announces the source refs the model's answer
# mentions — a JIRA ticket, a GitHub issue, an internal wiki page — as one
# line right after the turn:
#
#   sources: JIRA JIRA-123 → https://myjira.com/browse/JIRA-123, JIRA JIRA-10 → https://myjira.com/browse/JIRA-10
#
# Sources are configured patterns (config.yml, `bundles: source-links:`),
# so JIRA is just the first entry; any source can be added:
#
#   bundles:
#     source-links:
#       sources:
#         - name: JIRA
#           prefix: JIRA              # simple form: \bJIRA-(\d+)\b
#           base_url: https://myjira.com/browse/
#         - name: GitHub
#           pattern: '\bGH-(\d+)\b'   # full form: a regex
#           url: 'https://github.com/org/repo/issues/{match}'
#           case_insensitive: false   # optional, default false
#       max: 10                       # optional: refs per line, default 10
#
# The note is not stored in the conversation: it is an event, replayed by a
# UI only while the session's worker lives (a reload keeps it; a stopped
# worker loses it). The hook is inert until sources are configured.
class SourceLinks
  # The answer is scanned only up to this many characters: the primary
  # ReDoS guard, bounding the input a user-supplied regex can chew on.
  MAX_SCAN = 20_000
  # Refs per line before the "… +N more" tail.
  DEFAULT_MAX = 10
  # Per-regex timeout (Ruby 3.2+): a catastrophic pattern is abandoned
  # instead of hanging the turn. No global Regexp.timeout is touched. The
  # timeout is per match attempt, not per scan; MAX_SCAN bounds the total.
  REGEX_TIMEOUT = 0.5
  # A bare URL (scheme-anchored, so it can't start inside a markdown label),
  # and a markdown link (label in group 1, target in group 2).
  URL_SPAN = %r{[a-z][a-z0-9+.\-]*://\S+}i
  MARKDOWN_LINK = /\[([^\]]*)\]\(([^)]*)\)/

  def initialize(settings = {})
    settings = {} unless settings.is_a?(Hash)
    @sources = compile_sources(settings["sources"])
    max = settings["max"].to_i
    @max = max.positive? ? max : DEFAULT_MAX
  end

  def call(event)
    return unless event.is_a?(Hash) && event[:type] == :after_turn
    return unless event[:status].to_s == "completed"

    text = last_model_text(event[:messages])
    return if text.nil? || text.empty?

    found = collect(text[0, MAX_SCAN])
    return if found.empty?

    event[:notify]&.call(line(found), level: :info)
  end

  private

  # The content of the last `role: "model"` message, or nil. Handles both
  # string- and symbol-keyed messages. A turn that ended without a visible
  # answer stores a `kind: turn_note` system message instead, so the role
  # check alone is enough.
  def last_model_text(messages)
    Array(messages).reverse_each do |message|
      next unless message.is_a?(Hash)
      next unless (message.key?(:role) ? message[:role] : message["role"]).to_s == "model"

      content = message.key?(:content) ? message[:content] : message["content"]
      return content.to_s
    end
    nil
  end

  # [name, ref, url] for every ref found, in first-occurrence order (by the
  # ref's offset in the answer, whatever order the sources are configured
  # in), deduped by the ref text case-insensitively. A source whose regex
  # times out is skipped whole: its partial matches are discarded, the
  # others still report.
  def collect(text)
    url_spans = bare_url_spans(text)
    links = markdown_links(text)
    seen = {}
    found = []
    @sources.each do |source|
      hits = []
      local_seen = {}
      begin
        text.scan(source[:regex]) do
          match = Regexp.last_match
          ref = match[0]
          key = ref.downcase
          next if inside_any?(url_spans, match.begin(0), match.end(0))
          next if inside_markdown_link?(links, text, match)
          next if url_adjacent?(text, match)
          next if seen.key?(key) || local_seen.key?(key)

          local_seen[key] = true
          hits << [match.begin(0), source[:name], ref, source[:url].call(ref, match)]
        end
      rescue Regexp::TimeoutError
        Samagotchi::Log.warn(:hooks, "source_links_timeout",
                             echo: "[samagotchi:hooks] source-links: #{source[:name]} timed out; skipped")
        next
      end
      seen.merge!(local_seen)
      found.concat(hits)
    end
    found.sort_by! { |offset, _name, _ref, _url| offset }
    found.map { |_offset, name, ref, url| [name, ref, url] }
  end

  # The [start, end) character ranges of the answer that are a bare URL
  # (scheme-anchored, `[a-z][a-z0-9+.\-]*://\S+`). A ref inside one is not
  # linked again. The span stops at the first `)` that no `(` inside the URL
  # balances — so `(https://x.com/a)` ends before the `)`, while
  # `…/Foo_(bar)` keeps it.
  def bare_url_spans(text)
    spans = []
    text.scan(URL_SPAN) do
      match = Regexp.last_match
      finish = trim_url_end(match[0], match.begin(0), match.end(0))
      spans << [match.begin(0), finish] if finish > match.begin(0)
    end
    spans
  end

  # The end offset of a URL match after trimming its tail: the span stops at
  # the first `)` that no `(` inside the URL balances.
  def trim_url_end(url, start, finish)
    depth = 0
    url.each_char.with_index do |char, index|
      if char == "("
        depth += 1
      elsif char == ")"
        if depth.zero?
          finish = start + index
          break
        end
        depth -= 1
      end
    end
    finish
  end

  # A markdown link's label and target ranges, with the target text. A ref in
  # the target is a link destination (skip it); a ref in the label is skipped
  # only when the target names that same ref — `[JIRA-123](https://x.com/JIRA-123)`
  # is skipped, while `[fix for JIRA-123](https://github.com/o/r/pull/9)` still
  # links the ticket.
  def markdown_links(text)
    links = []
    text.scan(MARKDOWN_LINK) do
      match = Regexp.last_match
      links << { label: [match.begin(1), match.end(1)],
                 target: [match.begin(2), match.end(2)],
                 target_text: match[2].to_s }
    end
    links
  end

  def inside_any?(spans, start, finish)
    spans.any? { |span_start, span_end| start >= span_start && finish <= span_end }
  end

  def inside_markdown_link?(links, text, match)
    start = match.begin(0)
    finish = match.end(0)
    links.any? do |link|
      in_target = start >= link[:target][0] && finish <= link[:target][1]
      in_label = start >= link[:label][0] && finish <= link[:label][1]
      in_target || (in_label && target_names_ref?(link[:target_text], text[start...finish]))
    end
  end

  # True when the link target names the ref as a whole token: the lookarounds
  # reject a ref character (letter, digit or `-`) immediately before or after
  # the ref. So `[JIRA-1](…/JIRA-12)` is NOT skipped (the target names
  # JIRA-12), while `[JIRA-123](…/JIRA-123)` is. Note this is stricter than
  # the bare-text scan's `\b`, which treats `-` as a boundary: `…/JIRA-1-foo`
  # would match there but not here.
  def target_names_ref?(target, ref)
    escaped = Regexp.escape(ref)
    target.match?(/(?<![A-Za-z0-9\-])#{escaped}(?![A-Za-z0-9\-])/)
  end

  # A ref glued to URL punctuation is part of a link too, even when the span
  # scan misses it: `/browse/JIRA-1`, `?key=JIRA-1`, `JIRA-1/foo`. The
  # character right before is `/`, `=` or `?`, or the one right after is `/`.
  # `:` and `#` are NOT here: `Ticket:JIRA-5` and `#JIRA-123` are ordinary
  # plain-text ways to write a ticket, and a real URL is caught by the span
  # scan anyway.
  def url_adjacent?(text, match)
    start = match.begin(0)
    before = start.positive? ? text[start - 1] : nil
    after = text[match.end(0)]
    ["/", "=", "?"].include?(before) || after == "/"
  end

  def line(found)
    shown = found.first(@max)
    text = "sources: #{shown.map { |name, ref, url| "#{name} #{ref} → #{url}" }.join(', ')}"
    extra = found.size - shown.size
    text += ", … +#{extra} more" if extra.positive?
    text
  end

  def compile_sources(raw)
    Array(raw).filter_map { |entry| compile_source(entry) }
  end

  # One configured source as {name:, regex:, url:}, or nil (with a warn) for
  # an entry that is not a mapping, names neither a prefix nor a pattern, or
  # whose pattern does not compile. Never raises into the turn.
  def compile_source(entry)
    unless entry.is_a?(Hash)
      warn_invalid("a source entry must be a mapping, not #{entry.class}")
      return nil
    end

    entry = entry.transform_keys(&:to_s)
    name = entry["name"].to_s.strip
    prefix = entry["prefix"].to_s.strip
    pattern = entry["pattern"].to_s
    flags = entry["case_insensitive"] ? Regexp::IGNORECASE : 0

    if !prefix.empty?
      name = prefix if name.empty?
      regex = Regexp.new("\\b#{Regexp.escape(prefix)}-(\\d+)\\b", flags, timeout: REGEX_TIMEOUT)
      base = entry["base_url"].to_s
      { name: name, regex: regex, url: ->(ref, _match) { "#{base}#{ref}" } }
    elsif !pattern.empty?
      name = "source" if name.empty?
      regex = Regexp.new(pattern, flags, timeout: REGEX_TIMEOUT)
      template = entry["url"].to_s
      { name: name, regex: regex, url: ->(ref, match) { template.gsub("{match}", escape_url(match[1] || ref)) } }
    else
      warn_invalid("a source needs a prefix: or a pattern:")
      nil
    end
  rescue RegexpError => e
    warn_invalid("its pattern does not compile: #{e.message}")
    nil
  end

  def warn_invalid(reason)
    Samagotchi::Log.warn(:hooks, "source_links_invalid_source",
                         echo: "[samagotchi:hooks] source-links: skipping a source: #{reason}")
  end

  # A capture group is free-form, so escape what goes into the URL path.
  def escape_url(value)
    value.to_s.gsub(%r{[^A-Za-z0-9\-._~]}) { |c| c.bytes.map { |b| format("%%%02X", b) }.join }
  end
end
