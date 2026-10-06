# frozen_string_literal: true

# Loaded through module_eval: it requires what it uses.
require "open3"

# An after_turn hook that links the source refs the model's answer
# mentions — a JIRA ticket, a GitHub issue, an internal wiki page. In the
# web, each ref in the answer becomes a link (`[JIRA-123](https://…)`,
# through event[:present]: display only, the model's text stays as it was,
# and it survives a reload). Every UI also gets one line right after the
# turn, the terminals' only view of the links (marked fallback_for:
# :display when the answer links every URL it names, so the web with
# markdown on leaves it out; needs chi 0.35.0):
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
#         - name: Issues              # `#12` → this project's repo,
#                                     # `owner/repo#12` → that repo
#           pattern: '(?<![\w/&])(?:(?<repo>[A-Za-z0-9][\w-]*/[\w.-]*\w))?#(?<num>\d+)\b'
#           url: 'https://github.com/{repo}/issues/{num}'
#           remote: origin            # optional: the git remote {repo}/{host}
#                                     # come from, default origin
#           remote_host: github.com   # optional: a host or a list; else a
#                                     # remote on another host links nothing
#       max: 10                       # optional: refs per line, default 10
#       note: false                   # optional: no sources line (the web
#                                     # links stay), default true
#
# A `url:` template takes {match} (group 1, else the whole ref), {1}…{9}
# (numbered groups), {name} (named groups), and {repo}/{host}: the named
# group when it took part, else the project's (Dir.pwd's) git remote, asked
# of git once per worker. A {repo} the ref itself names ("other/repo#12")
# is that ref's own, so its {host} comes from the remote only when the
# source's `remote_host:` list has the remote's host: else the ref would
# link to this checkout's host with someone else's repo. A ref with a
# placeholder that can't be filled is not linked; a `{word}` that is none
# of these stays text (warned at load).
#
# The note is not stored in the conversation: it is an event, replayed by a
# UI with the session's cards (a reload keeps it, after the worker stopped
# too: cards.json). The links are stored as the answer's display. A ref in
# code (a `span` or a fenced block) or in a markdown link is not linked in
# the answer. The hook is inert until sources are configured.
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
  URL_SPAN = %r{[a-z][a-z0-9+.-]*://\S+}i
  MARKDOWN_LINK = /\[([^\]]*)\]\(([^)]*)\)/
  # A fenced code block's opening line (up to 3 spaces, then ``` or ~~~).
  FENCE_OPEN = /\A {0,3}(`{3,}|~{3,})/
  # A `{word}` or `{N}` placeholder in a `url:` template.
  PLACEHOLDER = /\{(\w+)\}/
  # Placeholders every pattern has: {match} (group 1, else the whole ref),
  # and {repo}/{host} (a named group, else the project's git remote).
  BUILTIN_PLACEHOLDERS = %w[match repo host].freeze
  # `git remote get-url` output: a URL with a scheme, `[user[:pw]@]host[:port]/path`.
  REMOTE_URL = %r{\A(?:https?|ssh|git)://(?:[^/]*@)?(\[[^\]]*\]|[^/:@]+)(?::[^/]*)?(/.*)?\z}i
  # scp-like `[user@]host:path`: a colon before any slash; a leading `/` or
  # `.` is a local path.
  REMOTE_SCP = %r{\A(?:[^@/:]+@)?([^/:.@][^/:@]*):(.*)\z}

  # The {host:, repo:} a git remote URL names, or nil (a local path,
  # `file://`, an empty path, or a path with an empty or dot segment).
  def self.parse_remote_url(url)
    url = url.to_s.strip
    # Any other scheme (file://, a transport helper's) is not a web host.
    match = url.include?("://") ? url.match(REMOTE_URL) : url.match(REMOTE_SCP)
    return nil unless match

    host = match[1]
    repo = match[2].to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "").delete_suffix(".git").sub(%r{/+\z}, "")
    segments = repo.split("/", -1)
    return nil if host.empty? || segments.empty? || segments.any? { |segment| ["", ".", ".."].include?(segment) }

    { host: host, repo: repo }
  end

  def initialize(settings = {})
    @sources = compile_sources(settings["sources"])
    max = settings["max"].to_i
    @max = max.positive? ? max : DEFAULT_MAX
    @note = settings["note"] != false
    # [Dir.pwd, remote name] => {host:, repo:} or nil, for the worker's life.
    @remotes = {}
    @host_mismatch_logged = {}
  end

  def call(event)
    return unless event.is_a?(Hash) && event[:type] == :after_turn
    return unless event[:status].to_s == "completed"
    return if @sources.empty?

    text = last_model_text(event[:messages])
    return if text.nil? || text.empty?

    hits = occurrences(text[0, MAX_SCAN])
    linked = present_links(event[:present], text, hits)
    return unless @note

    found = collect(hits)
    return if found.empty?

    # The display links every URL the note names: the note only stands in
    # for it, and a UI that renders the display's links leaves it out.
    covered = linked && found.all? { |_name, _ref, url| linked.key?(url.downcase) }
    event[:notify]&.call(line(found), level: :info, fallback_for: covered ? :display : nil)
  end

  private

  # Links the refs in the answer as shown: the model's text unless an
  # earlier hook changed it (then its offsets differ, so it is scanned
  # again). The URLs it linked (downcased, as #collect dedups), or nil when
  # the display didn't take them (no event[:present], nothing to present, or
  # the presenter rejected the text).
  def present_links(present, text, hits)
    return nil unless present

    linked = {}
    ours = nil
    shown = present.call { |display| ours = link(display, display == text ? hits : nil, linked) }
    ours.nil? || shown != ours ? nil : linked
  end

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

  # Every ref the note may name, as {start:, finish:, name:, ref:, url:,
  # quiet:}, by offset (whatever order the sources are configured in). The
  # skip rules below drop a ref that is already a link; +quiet+ marks one
  # the note names but the answer does not link (in code, or in a markdown
  # link's label: a link can't hold another). A source whose regex times out
  # is skipped whole: its partial matches are discarded, the others still
  # report.
  def occurrences(text)
    url_spans = bare_url_spans(text)
    links = markdown_links(text)
    code = code_spans(text)
    labels = links.map { |link| link[:label] }
    found = []
    @sources.each do |source|
      hits = []
      begin
        text.scan(source[:regex]) do
          match = Regexp.last_match
          start = match.begin(0)
          finish = match.end(0)
          next if inside_any?(url_spans, start, finish)
          next if inside_markdown_link?(links, text, match)
          next if url_adjacent?(text, match)

          # An unresolved placeholder: no link, from this source.
          url = source[:url].call(match[0], match)
          next if url.nil?

          quiet = inside_any?(code, start, finish) || inside_any?(labels, start, finish)
          hits << { start: start, finish: finish, name: source[:name], ref: match[0], url: url, quiet: quiet }
        end
      rescue Regexp::TimeoutError
        Samagotchi::Log.warn(:hooks, "source_links_timeout",
                             echo: "[samagotchi:hooks] source-links: #{source[:name]} timed out; skipped")
        next
      end
      found.concat(hits)
    end
    # By offset; on a tie (two sources on one ref) the first configured wins.
    found.each_with_index.sort_by { |hit, index| [hit[:start], index] }.map(&:first)
  end

  # [name, ref, url] for the note: first-occurrence order, deduped by the
  # URL case-insensitively (`#12` and `o/r#12` may name one issue; with
  # case_insensitive, `JIRA-1` and `jira-1` are one ticket).
  def collect(hits)
    seen = {}
    hits.filter_map do |hit|
      key = hit[:url].downcase
      next if seen.key?(key)

      seen[key] = true
      [hit[:name], hit[:ref], hit[:url]]
    end
  end

  # +text+ with each ref as a markdown link, every occurrence; the part
  # beyond MAX_SCAN stays as it is. +hits+ are the scan of that text when
  # the caller has it; +linked+ gets each linked URL, downcased.
  def link(text, hits = nil, linked = {})
    head = text[0, MAX_SCAN]
    hits ||= occurrences(head)
    out = +""
    pos = 0
    hits.each do |hit|
      next if hit[:quiet] || hit[:start] < pos # two sources on one ref: the first wins

      out << head[pos...hit[:start]] << "[#{hit[:ref].gsub(/[\[\]]/) { |c| "\\#{c}" }}](#{link_target(hit[:url])})"
      linked[hit[:url].downcase] = true
      pos = hit[:finish]
    end
    return text if pos.zero?

    out << head[pos..] << text[MAX_SCAN..].to_s
  end

  # A URL as a markdown link target: whitespace and what would end it
  # (parentheses, angle brackets) percent-encoded.
  def link_target(url)
    url.gsub(/[\s()<>]/) { |c| c.bytes.map { |b| format("%%%02X", b) }.join }
  end

  # The [start, end) ranges of the answer that are code: fenced blocks
  # (``` or ~~~, to the closing fence or the end) and inline spans (a run
  # of backticks to the next run of the same length). A line walk and a
  # lookup per backtick run, no regex over the whole answer.
  def code_spans(text)
    fences = fenced_blocks(text)
    runs = []
    text.scan(/`+/) { runs << [Regexp.last_match.begin(0), Regexp.last_match.end(0)] }
    runs.reject! { |start, finish| inside_any?(fences, start, finish) }
    by_length = Hash.new { |hash, key| hash[key] = [] }
    runs.each_with_index { |(start, finish), index| by_length[finish - start] << index }
    spans = []
    index = 0
    while index < runs.size
      start, finish = runs[index]
      same = by_length[finish - start]
      closing = same.bsearch { |other| other > index }
      if closing
        spans << [start, runs[closing][1]]
        index = closing + 1
      else
        index += 1
      end
    end
    fences + spans
  end

  def fenced_blocks(text)
    blocks = []
    open = nil
    offset = 0
    text.each_line do |line|
      marker = line[FENCE_OPEN, 1]
      if open.nil? && marker
        open = [offset, marker]
      elsif open && marker && marker[0] == open[1][0] && marker.length >= open[1].length && line.strip == marker
        blocks << [open[0], offset + line.length]
        open = nil
      end
      offset += line.length
    end
    blocks << [open[0], text.length] if open
    blocks
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
      in_target || (in_label && target_names_ref?(link[:target_text], text[start...finish],
                                                  case_insensitive: match.regexp.casefold?))
    end
  end

  # True when the link target names the ref as a whole token: the lookarounds
  # reject a ref character (letter, digit or `-`) immediately before or after
  # the ref. So `[JIRA-1](…/JIRA-12)` is NOT skipped (the target names
  # JIRA-12), while `[JIRA-123](…/JIRA-123)` is. Note this is stricter than
  # the bare-text scan's `\b`, which treats `-` as a boundary: `…/JIRA-1-foo`
  # would match there but not here. A case_insensitive source compares
  # without case too: `[jira-1](…/JIRA-1)` is skipped.
  def target_names_ref?(target, ref, case_insensitive: false)
    escaped = Regexp.escape(ref)
    flags = case_insensitive ? Regexp::IGNORECASE : 0
    target.match?(Regexp.new("(?<![A-Za-z0-9\\-])#{escaped}(?![A-Za-z0-9\\-])", flags))
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
    text = "sources: #{shown.map { |name, ref, url| "#{name} #{ref} → #{url}" }.join(", ")}"
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
      known = known_placeholders(name, template, regex)
      remote = entry["remote"].to_s.strip
      remote = "origin" if remote.empty?
      hosts = Array(entry["remote_host"]).map { |host| host.to_s.strip.downcase }.reject(&:empty?)
      source = { name: name, remote: remote, remote_hosts: hosts }
      source.merge(regex: regex, url: ->(ref, match) { render_url(template, known, match, ref, source) })
    else
      warn_invalid("a source needs a prefix: or a pattern:")
      nil
    end
  rescue RegexpError => e
    warn_invalid("its pattern does not compile: #{e.message}")
    nil
  end

  # The placeholders of +template+ this pattern can fill: {match}, {repo},
  # {host}, its named groups and {1}…{N} for its N groups. Any other
  # `{word}` stays as text, with one warning here, at compile time.
  def known_placeholders(name, template, regex)
    used = template.scan(PLACEHOLDER).flatten.uniq
    groups = group_count(regex)
    known, unknown = used.partition do |word|
      if word.match?(/\A\d+\z/)
        groups.nil? || word.to_i.between?(1, groups)
      else
        BUILTIN_PLACEHOLDERS.include?(word) || regex.names.include?(word)
      end
    end
    unless unknown.empty?
      list = unknown.map { |word| "{#{word}}" }.join(", ")
      Samagotchi::Log.warn(:hooks, "source_links_unknown_placeholder",
                           echo: "[samagotchi:hooks] source-links: #{name}: #{list}: no such group in its pattern; " \
                                 "left as text")
    end
    known
  end

  # How many groups +regex+ captures (with named groups, only those), found
  # by matching an always-empty alternative; nil when that fails.
  def group_count(regex)
    probe = Regexp.new("(?:#{regex.source}\n)|", regex.options, timeout: REGEX_TIMEOUT)
    probe.match("").size - 1
  rescue RegexpError # Regexp::TimeoutError is one
    nil
  end

  # The URL for one hit: +template+ with its +known+ placeholders filled, or
  # nil when one can't be (a group that didn't take part, a {repo} with an
  # empty or dot segment, no remote): we never build a URL with a hole.
  def render_url(template, known, match, ref, source)
    unresolved = false
    url = template.gsub(PLACEHOLDER) do
      word = Regexp.last_match(1)
      next Regexp.last_match(0) unless known.include?(word)

      value = placeholder_value(word, match, ref, source)
      unresolved = true if value.nil?
      value.to_s
    end
    unresolved ? nil : url
  end

  # One placeholder's escaped value, or nil when it is unresolved.
  def placeholder_value(word, match, ref, source)
    case word
    when "match" then escape_url(match[1] || ref)
    when /\A\d+\z/ then match[word.to_i]&.then { |value| escape_url(value) }
    when "repo", "host"
      value = match.names.include?(word) ? match[word] : nil
      value ||= remote_value(word, source, repo_from_match: match.names.include?("repo") ? match["repo"] : nil)
      word == "repo" ? escape_repo(value) : value&.then { |host| escape_url(host) }
    else match[word]&.then { |value| escape_url(value) }
    end
  end

  # {repo} / {host} from the project's git remote (the source's `remote:`,
  # default origin); nil when there is none, or when its host is not one of
  # the source's `remote_host:` list.
  #
  # +repo_from_match+: the match's own {repo}, when it has one. Such a ref
  # names its own repo (`other/repo#12`), not the local checkout's, so its
  # {host} may only come from the remote when the source lists that remote's
  # host (remote_host:): else the ref would link to the local remote's host
  # with someone else's repo.
  def remote_value(word, source, repo_from_match: nil)
    derived_host = word == "host" && !repo_from_match.to_s.empty?
    return nil if derived_host && source[:remote_hosts].empty?

    remote = project_remote(source[:remote])
    return nil unless remote

    hosts = source[:remote_hosts]
    unless hosts.empty? || hosts.include?(remote[:host].downcase)
      key = [source[:name], remote[:host]]
      unless @host_mismatch_logged[key]
        @host_mismatch_logged[key] = true
        Samagotchi::Log.debug(:hooks, "source_links_remote_host_mismatch", source: source[:name],
                                                                          host: remote[:host], remote_host: hosts.join(","))
      end
      return nil
    end
    remote[word.to_sym]
  end

  # The project's (Dir.pwd's) remote +name+ as {host:, repo:}, or nil.
  # Asked of git lazily (only a hit that needs it) and remembered, nil too,
  # per [Dir.pwd, name]: git applies insteadOf rewrites and includes, and a
  # worktree reports its main repo's remote.
  def project_remote(name)
    key = [Dir.pwd, name]
    return @remotes[key] if @remotes.key?(key)

    @remotes[key] = read_remote(key[0], name)
  end

  def read_remote(dir, name)
    out, status = Open3.capture2({ "GIT_DIR" => nil, "GIT_WORK_TREE" => nil },
                                 "git", "-C", dir, "remote", "get-url", name, err: File::NULL)
    unless status.success?
      Samagotchi::Log.debug(:hooks, "source_links_no_remote", remote: name, exit: status.exitstatus)
      return nil
    end
    remote = self.class.parse_remote_url(out)
    Samagotchi::Log.debug(:hooks, "source_links_remote", remote: name, host: remote&.dig(:host), repo: remote&.dig(:repo))
    remote
  rescue SystemCallError => e
    Samagotchi::Log.debug(:hooks, "source_links_no_remote", remote: name, error: e.class.name)
    nil
  end

  # A repo path with each `/`-separated segment escaped and the `/` kept
  # (GitLab's `group/sub/proj`); nil for an empty, `.` or `..` segment, which
  # a browser would resolve out of the path.
  def escape_repo(value)
    return nil if value.nil?

    segments = value.split("/", -1)
    return nil if segments.empty? || segments.any? { |segment| ["", ".", ".."].include?(segment) }

    segments.map { |segment| escape_url(segment) }.join("/")
  end

  def warn_invalid(reason)
    Samagotchi::Log.warn(:hooks, "source_links_invalid_source",
                         echo: "[samagotchi:hooks] source-links: skipping a source: #{reason}")
  end

  # A capture group is free-form, so escape what goes into the URL path.
  def escape_url(value)
    value.to_s.gsub(/[^A-Za-z0-9\-._~]/) { |c| c.bytes.map { |b| format("%%%02X", b) }.join }
  end
end
