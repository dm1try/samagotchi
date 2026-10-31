# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"
require "tmpdir"

# github-pr: a session on a branch with an open GitHub PR gets the PR
# proposed as a candidate (docs/context.md, Candidates) when its worker
# starts: a quiet init task asks git for the branch and gh for its PR, and
# proposes it through this bundle's provider (manifest context_providers,
# which also serves `chi context add <PR URL>` and the web's "+ URL"),
# titled "#N <title>", mentioned by "#N", the branch and the URL. chi
# attaches it once the owner mentions one of them. Nothing for a scratch
# session, and nothing, quietly, without gh, its login, a repo or an open
# PR. At a turn's start, more than RELOOK_SECONDS after the last look, it
# looks again on a thread of its own (a branch switched mid-session).
#
# Line links: in the web, a `lib/foo.rb:28` (or `lib/foo.rb:28-34`, in
# inline code too) in the model's answer links to that line of the PR the
# session reviews: the PR's Files changed view when the lines are in a
# hunk, else the file at the PR's head. The PRs are the session's attached
# github-pr sources and the PR URLs in the user's messages (a delegate
# child's task is its first one). Display only (event[:present]): the
# model's text stays as it was. Each linked ref is also a file ref on the
# answer (event[:refs], chi 0.61.0): the file in this checkout, with a "PR
# diff" (or "File at head") action the web's ref menu offers. The
# after_turn hook links from a per-PR cache and never runs gh (the web holds the answer until the hooks are
# done); before_turn, before_generation and the init task fill the cache
# off the turn's thread (`gh api`), in a session worker only: the REPL and
# -p --non-interactive show no web page while they run (ctx.frontend; a chi
# without it counts as a worker), and a scratch session never fetches.
# `bundles: github-pr: line_links:` false turns it off, "always" fetches in
# the REPL and -p too (still not for a scratch session).
#
# `bundles: github-pr: auto_attach:` says what the init task does with the
# branch's open PR: `propose` (the default, above), `attach` (attached at
# once, the old default: not for a delegate child, D12) or `off`
# (nothing). `offer` (the card it once posted) is read as `propose`.
class Plugin
  # gh and git each get this long (a network hang must not keep a thread).
  COMMAND_SECONDS = 20
  # before_generation looks for a newly attached PR at most this often.
  GENERATION_CHECK_SECONDS = 30
  # line_links' values: off, a worker's only (the default), every frontend.
  LINE_LINKS_MODES = { false => :off, true => :worker, "always" => :always }.freeze
  # auto_attach's values (YAML's bare true/false: attach/off). `offer`, the
  # card it once posted, reads as propose (warned once).
  AUTO_ATTACH_MODES = { "propose" => :propose, "attach" => :attach, "offer" => :propose, "off" => :off, true => :attach,
                        false => :off }.freeze
  # A turn's start looks for the branch's PR again after this long.
  RELOOK_SECONDS = 300
  # A git remote URL's GitHub owner and repo (https, ssh or scp-like).
  REMOTE_REPO = %r{github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?\z}i

  def initialize
    @cache = PrCache.new
    @generation_checked_at = nil
    @warned_mode = false
    @looked_at = nil
    @look_mutex = Mutex.new
    @looking = false
    @warned_line_links = false
    # cwd => the "owner/repo"s (downcased) its git remotes name on
    # github.com, for the worker's life.
    @checkout_repos = {}
  end

  def register(chi)
    chi.init("Looking for this branch's pull request", quiet: true) do |ctx|
      summary = look(ctx)
      # Inline (an init task has its own thread), whatever the attach
      # returned (attached already, a child, a scratch session), and after
      # it, so a PR it just attached is warm for the first answer.
      refresh(ctx, attached_prs(ctx)) if prefetch?(ctx)
      summary
    end
    chi.on(:before_turn) do |event, ctx|
      # The prompt too: messages is the history before this turn, and a
      # delegate child's task is its first prompt.
      kick(ctx, attached_prs(ctx) + PrRef.from_messages(event[:messages], prompt: event[:prompt])) if prefetch?(ctx)
      relook(ctx)
    end
    chi.on(:before_generation) { |_event, ctx| check_attached(ctx) }
    # After source-links (90): its links are in the display this one gets.
    chi.on(:after_turn, priority: 100) { |event, ctx| link_answer(event, ctx) }
  end

  # @return [String] what it did (the init task's summary)
  def attach_branch_pr(ctx)
    return "skipped: a scratch session" if ctx.scratch?
    return "no session yet" unless ctx.session_id

    mode = auto_attach_mode(ctx)
    return "auto_attach: off" if mode == :off
    return "skipped: a delegate child" if mode == :attach && ctx.delegate?
    return "skipped: a review session" if mode == :propose && ctx.review?

    branch = run(ctx, "git", "branch", "--show-current").to_s.strip
    return "not on a branch" if branch.empty?

    json = run(ctx, "gh", "pr", "view", "--json", "number,url,state,title") or return "no pull request for #{branch}"
    pr = JSON.parse(json)
    return "pull request ##{pr["number"]} isn't open" unless pr["state"] == "OPEN"

    name = "pr-#{pr["number"]}"
    return "#{name} is attached already" if ctx.context.list.any? { |source| source[:name] == name || source[:hint] == pr["url"] }
    return propose_branch_pr(ctx, branch, pr, name) if mode == :propose

    attached = ctx.context.attach(url: pr["url"], name: name, why: "branch #{branch} has open PR ##{pr["number"]}")
    attached ? "attached #{name}" : "#{name} was removed from this session; not attached again"
  rescue StandardError => e
    ctx.log.info(:pr_not_attached, error: e.class.name, msg: e.message.to_s[0, 200])
    "no pull request attached"
  end

  # `bundles: github-pr: auto_attach:`, read at each look.
  # @return [Symbol] :propose, :attach or :off; `offer` and an unknown
  #   value are :propose (logged once)
  def auto_attach_mode(ctx)
    value = ctx.settings["auto_attach"]
    return :propose if value.nil?

    key = value.is_a?(String) ? value.strip.downcase : value
    warn_mode(ctx, :pr_auto_attach_offer_is_propose, value) if key == "offer"
    AUTO_ATTACH_MODES.fetch(key) do
      warn_mode(ctx, :pr_auto_attach_unknown, value)
      :propose
    end
  end

  # #attach_branch_pr, remembering when (a turn's start looks again after
  # RELOOK_SECONDS).
  def look(ctx)
    @look_mutex.synchronize { @looked_at = now }
    attach_branch_pr(ctx)
  end

  # A turn's start: the branch's PR looked for again, on a thread of its
  # own (git and gh never hold the turn), when the last look is more than
  # RELOOK_SECONDS old and none runs. Propose mode only: attach mode
  # attaches at the worker's start alone, as it always did.
  def relook(ctx)
    return if ctx.scratch? || auto_attach_mode(ctx) != :propose

    claimed = @look_mutex.synchronize do
      next false if @looking || @looked_at.nil? || now - @looked_at < RELOOK_SECONDS

      @looking = true
    end
    return unless claimed

    thread = Thread.new do
      ctx.log.debug(:pr_relooked, summary: look(ctx))
    ensure
      @look_mutex.synchronize { @looking = false }
    end
    thread.report_on_exception = false
    thread
  end

  # The after_turn handler: links the answer's `path:line` refs from the
  # PRs' cached data. Never runs gh: nothing cached yet links nothing.
  def link_answer(event, ctx)
    return unless line_links?(ctx) && event[:status].to_s == "completed" && event[:present]

    text = LineLinker.last_model_text(event[:messages])
    return if text.nil? || !text.match?(LineLinker::QUICK)

    prs = (attached_prs(ctx) + PrRef.from_messages(event[:messages])).uniq
    cached = prs.filter_map { |pr| (data = @cache[pr]) && [pr, data] }
    return if cached.empty?

    linker = LineLinker.new(cached)
    event[:present].call { |display| linker.link(display) }
    add_refs(event[:refs], linker.found, ctx) unless linker.found.empty?
  end

  # Each linked `path:line` as a file ref on the answer (event[:refs]): its
  # target the file in this checkout (its root + the PR path), its action
  # the link's URL, named by what it opens. Only for a PR of this
  # checkout's repo (one of its git remotes names it): another project's PR
  # has its files elsewhere, so its links stay links.
  def add_refs(refs, found, ctx)
    return unless refs

    root = project_root(ctx)
    return unless root

    repos = checkout_repos(ctx)
    found.each do |hit|
      next unless repos.include?(hit[:repo].downcase)

      action = hit[:diff] ? { id: "pr_diff", label: "PR diff", url: hit[:url] } : { id: "blob", label: "File at #{hit[:at]}", url: hit[:url] }
      refs.call(match: hit[:match], kind: "file", label: nil, actions: [action],
                target: { path: File.join(root, hit[:path]), line: hit[:line], end_line: hit[:end_line] })
    end
  end

  # The GitHub "owner/repo"s (downcased) the checkout's git remotes name
  # (`git remote -v`: a fork's upstream too), asked once per cwd.
  def checkout_repos(ctx)
    @checkout_repos[ctx.cwd] ||= run(ctx, "git", "remote", "-v").to_s.each_line.filter_map do |line|
      match = line.split(/\s+/)[1].to_s.match(REMOTE_REPO)
      "#{match[1]}/#{match[2]}".downcase if match
    end.uniq
  end

  # Fetches the PRs in +prs+ whose cache entry is missing or old, on this
  # thread, unless a refresh runs already (the init task; #kick's thread).
  def refresh(ctx, prs)
    stale = @cache.stale(prs.uniq, now)
    return if stale.empty? || !@cache.claim

    begin
      stale.each { |pr| fetch(ctx, pr) }
    ensure
      @cache.release
    end
  end

  private

  # `bundles: github-pr: line_links:`: :off, :worker (true or unset) or
  # :always; an unknown value (a quoted "false") is :worker, logged once.
  def line_links_mode(ctx)
    value = ctx.settings["line_links"]
    return :worker if value.nil?

    LINE_LINKS_MODES.fetch(value.is_a?(String) ? value.strip.downcase : value) do
      ctx.log.warn(:pr_line_links_unknown, value: value.to_s[0, 40]) unless @warned_line_links
      @warned_line_links = true
      :worker
    end
  end

  def line_links?(ctx) = line_links_mode(ctx) != :off

  # Whether to fetch PR data for line links (gh api): not for a scratch
  # session (gone at exit), and by default only in a session worker, the
  # one frontend whose answers the web shows while it runs. A chi before
  # ctx.frontend (0.49.0) counts as a worker.
  def prefetch?(ctx)
    return false if ctx.scratch?

    case line_links_mode(ctx)
    when :off then false
    when :always then true
    else (ctx.respond_to?(:frontend) ? ctx.frontend : :worker) == :worker
    end
  end

  # Propose mode: the PR as a candidate; an owner prompt already in the
  # session that mentions it attaches it at once (ctx.context.propose).
  def propose_branch_pr(ctx, branch, pr, name)
    number = pr["number"]
    title = "##{number} #{pr["title"].to_s.gsub(/\s+/, " ").strip}".strip
    proposed = ctx.context.propose(url: pr["url"], name: name, title: title, mentions: ["##{number}", branch, pr["url"]])
    proposed ? "proposed #{name}" : "#{name} was removed from this session; not proposed"
  end

  def warn_mode(ctx, event, value)
    ctx.log.warn(event, value: value.to_s[0, 40]) unless @warned_mode
    @warned_mode = true
  end

  def project_root(ctx)
    ctx.repo_root
  rescue StandardError
    nil
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # #refresh on its own thread (a raw one, docs/plugins.md), when there is
  # something to fetch and no refresh runs. Process exit ends it; a gh
  # still running then finishes alone.
  def kick(ctx, prs)
    prs = prs.uniq
    return if prs.empty? || @cache.refreshing? || @cache.stale(prs, now).empty?

    thread = Thread.new { refresh(ctx, prs) }
    thread.report_on_exception = false
  end

  # A PR attached while the turn runs (a parent attaching it right after
  # `delegate wait: false`), checked at most every GENERATION_CHECK_SECONDS.
  def check_attached(ctx)
    return unless prefetch?(ctx)
    return if @generation_checked_at && now - @generation_checked_at < GENERATION_CHECK_SECONDS

    @generation_checked_at = now
    kick(ctx, attached_prs(ctx))
  end

  # The session's attached github-pr sources, as PrRefs.
  def attached_prs(ctx)
    ctx.context.list.filter_map { |source| PrRef.parse(source[:hint]) if source[:provider] == "github-pr" }
  rescue StandardError => e
    ctx.log.debug(:pr_lines_no_sources, error: e.class.name)
    []
  end

  # The PR's head and base, and its files when the head moved (or none
  # are cached). A failure is remembered, so the next kicks wait.
  def fetch(ctx, pr)
    shas = run(ctx, "gh", "api", "repos/#{pr.owner}/#{pr.repo}/pulls/#{pr.number}", "--jq",
               '.head.sha + " " + .base.sha', chdir: Dir.tmpdir).to_s.split
    return failed(ctx, pr, "no pull request data") unless shas.size == 2

    cached = @cache[pr]
    files = cached.files if cached && cached.head_sha == shas[0]
    files ||= fetch_files(ctx, pr) or return failed(ctx, pr, "no file list")
    @cache.store(pr, PrData.new(head_sha: shas[0], base_sha: shas[1], files: files, fetched_at: now))
    ctx.log.debug(:pr_lines_fetched, pr: pr.url, files: files.size)
  rescue StandardError => e
    failed(ctx, pr, "#{e.class.name}: #{e.message.to_s[0, 200]}")
  end

  # The PR's files, one JSON object a line (--jq), every page.
  def fetch_files(ctx, pr)
    out = run(ctx, "gh", "api", "--paginate", "repos/#{pr.owner}/#{pr.repo}/pulls/#{pr.number}/files?per_page=100",
              "--jq", ".[] | {filename, status, previous_filename, patch}", chdir: Dir.tmpdir) or return nil
    out.each_line.filter_map { |line| PrFile.from_api(JSON.parse(line)) unless line.strip.empty? }
  end

  # Logged once per PR until a fetch of it succeeds (no gh, no login, no
  # network: every kick would say it again).
  def failed(ctx, pr, why)
    ctx.log.info(:pr_lines_not_fetched, pr: pr.url, why: why) if @cache.fail(pr, now)
    nil
  end

  # stdout of a command that succeeded within COMMAND_SECONDS, else nil.
  def run(ctx, *command, chdir: ctx.cwd)
    Open3.popen2(*command, chdir: chdir, err: File::NULL, pgroup: true) do |stdin, stdout, wait|
      stdin.close
      reader = Thread.new { stdout.read }
      unless wait.join(COMMAND_SECONDS)
        begin
          Process.kill("KILL", -wait.pid)
        rescue SystemCallError
          nil
        end
        return nil
      end
      output = reader.value
      wait.value.success? ? output : nil
    end
  rescue SystemCallError
    nil
  end
end

# A GitHub pull request, by its URL.
PrRef = Data.define(:owner, :repo, :number)

class PrRef
  # A PR URL anywhere in a text (trailing text allowed, like the provider's
  # match: `…/pull/42/files`).
  URL = %r{https://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)}
  # PRs taken from the user's messages, newest first.
  FROM_MESSAGES = 3

  # @return [PrRef, nil]
  def self.parse(text)
    match = text.to_s.match(URL) or return nil
    new(owner: match[1], repo: match[2], number: match[3].to_i)
  end

  # The PRs the user's messages (and +prompt+, the turn's own) name, newest
  # first, up to FROM_MESSAGES distinct. Not tool results or answers: `gh pr
  # list` output, logs or a CHANGELOG name unrelated PRs.
  def self.from_messages(messages, prompt: nil)
    texts = Array(messages).filter_map do |message|
      next unless message.is_a?(Hash)

      role = message.key?(:role) ? message[:role] : message["role"]
      (message.key?(:content) ? message[:content] : message["content"]).to_s if role.to_s == "user"
    end
    texts << prompt.to_s if prompt
    found = []
    texts.reverse_each do |text|
      text.scan(URL).reverse_each do |owner, repo, number|
        pr = new(owner: owner, repo: repo, number: number.to_i)
        found << pr unless found.include?(pr)
        return found if found.size >= FROM_MESSAGES
      end
    end
    found
  end

  def url = "https://github.com/#{owner}/#{repo}/pull/#{number}"
end

# One file of a PR: its path (the new name), a rename's old one, its status
# ("added", "modified", "removed", "renamed", …) and its hunks as line
# ranges on each side (none: a binary file or too large a diff).
PrFile = Data.define(:path, :previous_path, :status, :new_hunks, :old_hunks)

class PrFile
  # A hunk header: `@@ -a,b +c,d @@` (a count left out is 1).
  HUNK = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

  # @param file [Hash] one entry of the PR files API
  # @return [PrFile, nil]
  def self.from_api(file)
    return nil unless file.is_a?(Hash) && file["filename"].is_a?(String)

    old_hunks = []
    new_hunks = []
    file["patch"].to_s.scan(HUNK) do |old_start, old_count, new_start, new_count|
      old_hunks << span(old_start, old_count)
      new_hunks << span(new_start, new_count)
    end
    new(path: file["filename"], previous_path: file["previous_filename"], status: file["status"].to_s,
        new_hunks: new_hunks.compact, old_hunks: old_hunks.compact)
  end

  # A hunk side's lines, or nil for none (`+0,0`: a removed file).
  def self.span(start, count)
    count = (count || 1).to_i
    count.zero? ? nil : start.to_i..(start.to_i + count - 1)
  end

  def removed? = status == "removed"
end

# What the cache holds of a PR.
PrData = Data.define(:head_sha, :base_sha, :files, :fetched_at)

# The PRs' data, per PR, shared by the hooks' threads and the refresh's.
class PrCache
  # An entry (or a failed fetch) younger than this isn't fetched again.
  FRESH_SECONDS = 60

  def initialize
    @mutex = Mutex.new
    @entries = {}
    @failed = {}
    @refreshing = false
  end

  # @return [PrData, nil]
  def [](pr) = @mutex.synchronize { @entries[pr] }

  def store(pr, data)
    @mutex.synchronize do
      @entries[pr] = data
      @failed.delete(pr)
    end
  end

  # Remembers a failed fetch; true the first time since the last success.
  def fail(pr, time)
    @mutex.synchronize do
      first = !@failed.key?(pr)
      @failed[pr] = time
      first
    end
  end

  # The PRs whose entry is missing or older than FRESH_SECONDS (a recent
  # failure counts as fresh).
  def stale(prs, time)
    @mutex.synchronize do
      prs.reject do |pr|
        fetched = [@entries[pr]&.fetched_at, @failed[pr]].compact.max
        fetched && time - fetched < FRESH_SECONDS
      end
    end
  end

  # Takes the one refresh slot: false when a refresh runs.
  def claim
    @mutex.synchronize do
      next false if @refreshing

      @refreshing = true
    end
  end

  def release = @mutex.synchronize { @refreshing = false }

  def refreshing? = @mutex.synchronize { @refreshing }
end

# Links an answer's `path:line` and `path:line-line` refs to the PRs'
# lines. A ref in inline code links when the code is the ref alone
# (`` `foo.rb:28` `` becomes ``[`foo.rb:28`](url)``); fenced blocks,
# markdown links and bare URLs are left alone.
class LineLinker
  # The answer is scanned only up to this many characters.
  MAX_SCAN = 20_000
  # A path (no spaces), a line, an optional end line and an optional
  # column (kept in the link's text, not used).
  REF = %r{(?<![\w./@+~-])(?<path>[\w./@+~-]*[\w@+~-]):(?<from>\d+)(?:-(?<to>\d+))?(?::\d+)?(?![\w/])}
  REF_ALONE = /\A#{REF}\z/
  # Whether an answer may hold a ref at all.
  QUICK = /\S:\d/
  URL_SPAN = %r{[a-z][a-z0-9+.-]*://\S+}i
  MARKDOWN_LINK = /\[[^\]]*\]\([^)]*\)/
  # A fenced code block's opening line (up to 3 spaces, then ``` or ~~~).
  FENCE_OPEN = /\A {0,3}(`{3,}|~{3,})/

  # The content of the last model message, or nil (string or symbol keys).
  def self.last_model_text(messages)
    Array(messages).reverse_each do |message|
      next unless message.is_a?(Hash)
      next unless (message.key?(:role) ? message[:role] : message["role"]).to_s == "model"

      return (message.key?(:content) ? message[:content] : message["content"]).to_s
    end
    nil
  end

  # The refs the last #link linked, in order: {match:, url:, diff:, at:,
  # repo:, path:, line:, end_line:} (+match+ the ref's text, inline code's
  # without its backticks; +diff+ true for a PR diff URL, else +at+ "head"
  # or "base", the sha of the file's URL; +repo+ the PR's "owner/repo";
  # +path+ the PR's path of the file).
  attr_reader :found

  # @param prs [Array<Array(PrRef, PrData)>]
  def initialize(prs)
    @prs = prs
    @found = []
  end

  # +text+ with each ref that names exactly one PR's file as a markdown
  # link; the part beyond MAX_SCAN stays as it is.
  def link(text)
    head = text[0, MAX_SCAN]
    out = +""
    pos = 0
    @found = []
    hits(head).each do |start, finish, hit|
      out << head[pos...start] << "[#{head[start...finish]}](#{hit[:url]})"
      @found << hit
      pos = finish
    end
    return text if pos.zero?

    out << head[pos..] << text[MAX_SCAN..].to_s
  end

  # {url:, diff:, path:, line:, end_line:} for +path+'s lines +from+..+to+
  # (+to+ nil: one line), or nil: no PR has the file, or more than one does.
  def line_for(path, from, to = nil)
    found = @prs.filter_map do |pr, data|
      file = resolve(data.files, path)
      [pr, data, file] if file
    end
    return nil unless found.size == 1

    line_url(*found.first, from, to)
  end

  private

  # [start, finish, hit] for each ref to link, by offset (+hit+ as #found's).
  def hits(text)
    fences = fenced_blocks(text)
    skipped = fences + spans(text, URL_SPAN) + spans(text, MARKDOWN_LINK)
    code = inline_code(text, fences)
    found = []
    code.each do |start, finish, inner|
      next if inside_any?(skipped, start, finish)

      match = inner.strip.match(REF_ALONE) or next
      hit = ref_line(match) and found << [start, finish, hit.merge(match: match[0])]
    end
    text.scan(REF) do
      match = Regexp.last_match
      start = match.begin(0)
      finish = match.end(0)
      next if inside_any?(skipped, start, finish) || inside_any?(code, start, finish)

      hit = ref_line(match) and found << [start, finish, hit.merge(match: match[0])]
    end
    found.sort_by(&:first)
  end

  # A path has a `/` or an extension (`10:30` is a time, `host:8080` a port).
  def ref_line(match)
    path = match[:path]
    return nil unless path.include?("/") || path.match?(/\.[A-Za-z0-9]+\z/)

    from = match[:from].to_i
    to = match[:to]&.to_i
    to = nil if to && to <= from
    from.zero? ? nil : line_for(path, from, to)
  end

  # The PR file +path+ names: the path (or a rename's old one) exactly,
  # after a leading `./`; else, for an absolute path (into a worktree) or
  # one up from the cwd (`../lib/foo.rb` from a subdir), the longest PR
  # path it ends with on a `/` boundary (see #worktree_suffix); else the
  # one PR path that ends with +path+ (a bare `foo.rb`). nil: none, or
  # several. A relative path that only ends with a PR path
  # (`vendor/lib/foo.rb`) is another file.
  def resolve(files, path)
    path = path.sub(%r{\A(?:\./)+}, "")
    exact = files.find { |file| file.path == path } || files.find { |file| file.previous_path == path }
    return exact if exact

    if path.start_with?("/", "~/", "../")
      longer = files.select { |file| path.end_with?("/#{file.path}") }.sort_by { |file| -file.path.length }
      return path.start_with?("../") ? longer.first : worktree_suffix(longer, path)
    end

    shorter = files.select { |file| file.path.end_with?("/#{path}") }
    shorter.one? ? shorter.first : nil
  end

  # The first of +files+ (longest path first) that the absolute +path+
  # names inside a worktree: the part before the PR path is a directory
  # with a `.git` (/abs/repo/vendor/lib/foo.rb is a vendored copy, not the
  # PR's lib/foo.rb), or no directory here at all (a path from elsewhere;
  # nothing to tell by). nil: each part before is a directory, none a
  # worktree's root.
  def worktree_suffix(files, path)
    full = File.expand_path(path)
    files.find do |file|
      root = full.delete_suffix("/#{file.path}")
      !File.directory?(root) || File.exist?(File.join(root, ".git"))
    end
  rescue ArgumentError
    files.first
  end

  # The PR's Files changed anchor when the lines are inside one hunk (the
  # new side; a removed file's old side), else the file at the PR's head
  # (a removed one: at its base), which has every line. As #line_for's
  # hash.
  def line_url(pr, data, file, from, to)
    last = to || from
    lines = { path: file.path, line: from, end_line: to, repo: "#{pr.owner}/#{pr.repo}" }
    hunks, side = file.removed? ? [file.old_hunks, "L"] : [file.new_hunks, "R"]
    if hunks.any? { |hunk| hunk.cover?(from) && hunk.cover?(last) }
      anchor = "#{side}#{from}#{"-#{side}#{to}" if to}"
      return { url: "#{pr.url}/files#diff-#{Digest::SHA256.hexdigest(file.path)}#{anchor}", diff: true, at: nil, **lines }
    end

    sha = file.removed? ? data.base_sha : data.head_sha
    path = file.path.split("/").map { |segment| segment.gsub(/[^\w.~-]/) { |c| c.bytes.map { |b| format("%%%02X", b) }.join } }
    { url: "https://github.com/#{pr.owner}/#{pr.repo}/blob/#{sha}/#{path.join("/")}#L#{from}#{"-L#{to}" if to}", diff: false,
      at: file.removed? ? "base" : "head", **lines }
  end

  # [start, finish, inner] for each inline code span outside +fences+: a
  # run of backticks to the next run of the same length.
  def inline_code(text, fences)
    runs = []
    text.scan(/`+/) { runs << [Regexp.last_match.begin(0), Regexp.last_match.end(0)] }
    runs.reject! { |start, finish| inside_any?(fences, start, finish) }
    by_length = Hash.new { |hash, key| hash[key] = [] }
    runs.each_with_index { |(start, finish), index| by_length[finish - start] << index }
    found = []
    index = 0
    while index < runs.size
      start, finish = runs[index]
      closing = by_length[finish - start].bsearch { |other| other > index }
      if closing
        found << [start, runs[closing][1], text[finish...runs[closing][0]]]
        index = closing + 1
      else
        index += 1
      end
    end
    found
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

  def spans(text, regex)
    found = []
    text.scan(regex) { found << [Regexp.last_match.begin(0), Regexp.last_match.end(0)] }
    found
  end

  def inside_any?(spans, start, finish)
    spans.any? { |span_start, span_end| start >= span_start && finish <= span_end }
  end
end
