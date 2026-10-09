# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "time"
require "tmpdir"

# github-pr: a session on a branch with an open GitHub PR gets the PR
# attached as context (docs/context.md) when its worker starts: a quiet
# init task asks git for the branch and gh for its PR, and attaches it
# through this bundle's provider (manifest context_providers, which also
# serves `chi context add <PR URL>` and the web's "+ URL"). Nothing for a
# scratch session or a delegate child (D12), and nothing, quietly, without
# gh, its login, a repo or an open PR.
#
# Line links: in the web, a `lib/foo.rb:28` (or `lib/foo.rb:28-34`, in
# inline code too) in the model's answer links to that line of the PR the
# session reviews: the PR's Files changed view when the lines are in a
# hunk, else the file at the PR's head. The PRs are the session's attached
# github-pr sources and the PR URLs in the user's messages (a delegate
# child's task is its first one). Display only (event[:present]): the
# model's text stays as it was. The after_turn hook links from a per-PR
# cache and never runs gh (the web holds the answer until the hooks are
# done); before_turn, before_generation and the init task fill the cache
# off the turn's thread. `bundles: github-pr: line_links: false` turns it
# off.
#
# `bundles: github-pr: auto_attach:` says what the init task does with the
# branch's open PR: `attach` (the default), `offer` (a card with Attach and
# Not here, which run /pr-attach N and /pr-decline N; nothing attached until
# a click; offered once per session) or `off` (nothing). In offer mode the
# offers, their outcomes and each session's first prompt go to
# <data_dir>/offers.ndjson (OffersLog), to find heuristics later.
class Plugin
  # gh and git each get this long (a network hang must not keep a thread).
  COMMAND_SECONDS = 20
  # before_generation looks for a newly attached PR at most this often.
  GENERATION_CHECK_SECONDS = 30
  # auto_attach's values (YAML's bare true/false: attach/off).
  AUTO_ATTACH_MODES = { "attach" => :attach, "offer" => :offer, "off" => :off, true => :attach, false => :off }.freeze
  # /pr-attach and /pr-decline take a PR number (`42` or `#42`).
  PR_NUMBER = /\A#?(\d+)\z/
  # The offer card's line under the PR's title.
  OFFER_LINE = "Not attached: the agent gets nothing until you attach it."
  # first_prompt keeps this much of the prompt.
  FIRST_PROMPT_CHARS = 160

  def initialize
    @cache = PrCache.new
    @generation_checked_at = nil
    @warned_mode = false
  end

  def register(chi)
    chi.init("Looking for this branch's pull request", quiet: true) do |ctx|
      summary = attach_branch_pr(ctx)
      # Inline (an init task has its own thread), whatever the attach
      # returned (attached already, a child, a scratch session), and after
      # it, so a PR it just attached is warm for the first answer.
      refresh(ctx, attached_prs(ctx)) if line_links?(ctx)
      summary
    end
    chi.on(:before_turn) do |event, ctx|
      # The prompt too: messages is the history before this turn, and a
      # delegate child's task is its first prompt.
      kick(ctx, attached_prs(ctx) + PrRef.from_messages(event[:messages], prompt: event[:prompt])) if line_links?(ctx)
      log_first_prompt(event, ctx)
    end
    chi.command("/pr-attach", "Attach the PR this session was offered: /pr-attach 42", anytime: true) do |args, ctx|
      offer_command("/pr-attach", args, ctx) { |number, offer| attach_offered(ctx, number, offer) }
    end
    chi.command("/pr-decline", "Don't attach the PR this session was offered: /pr-decline 42", anytime: true) do |args, ctx|
      offer_command("/pr-decline", args, ctx) { |number, offer| decline_offered(ctx, number, offer) }
    end
    chi.on(:before_generation) { |_event, ctx| check_attached(ctx) }
    # After source-links (90): its links are in the display this one gets.
    chi.on(:after_turn, priority: 100) { |event, ctx| link_answer(event, ctx) }
  end

  # @return [String] what it did (the init task's summary)
  def attach_branch_pr(ctx)
    return "skipped: a scratch session" if ctx.scratch?
    return "skipped: a delegate child" if ctx.delegate?
    return "no session yet" unless ctx.session_id

    mode = auto_attach_mode(ctx)
    return "auto_attach: off" if mode == :off

    branch = run(ctx, "git", "branch", "--show-current").to_s.strip
    return "not on a branch" if branch.empty?

    json = run(ctx, "gh", "pr", "view", "--json", "number,url,state,title") or return "no pull request for #{branch}"
    pr = JSON.parse(json)
    return "pull request ##{pr["number"]} isn't open" unless pr["state"] == "OPEN"

    name = "pr-#{pr["number"]}"
    return "#{name} is attached already" if ctx.context.list.any? { |source| source[:name] == name || source[:hint] == pr["url"] }
    return offer_branch_pr(ctx, branch, pr, name) if mode == :offer

    attached = ctx.context.attach(url: pr["url"], name: name, why: "branch #{branch} has open PR ##{pr["number"]}")
    attached ? "attached #{name}" : "#{name} was removed from this session; not attached again"
  rescue StandardError => e
    ctx.log.info(:pr_not_attached, error: e.class.name, msg: e.message.to_s[0, 200])
    "no pull request attached"
  end

  # `bundles: github-pr: auto_attach:`, read at each worker start.
  # @return [Symbol] :attach, :offer or :off; an unknown value is :attach
  #   (logged once)
  def auto_attach_mode(ctx)
    value = ctx.settings["auto_attach"]
    return :attach if value.nil?

    key = value.is_a?(String) ? value.strip.downcase : value
    AUTO_ATTACH_MODES.fetch(key) do
      ctx.log.warn(:pr_auto_attach_unknown, value: value.to_s[0, 40]) unless @warned_mode
      @warned_mode = true
      :attach
    end
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

    event[:present].call { |display| LineLinker.new(cached).link(display) }
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

  def line_links?(ctx) = ctx.settings["line_links"] != false

  def offer_card_id(number) = "github-pr-offer-#{number}"

  # Offer mode: a card instead of the attach, once per session per PR (a
  # worker restart finds the offered marker). The marker is written after
  # the card, so a card that failed leaves none.
  def offer_branch_pr(ctx, branch, pr, name)
    return "#{name} was removed from this session; not offered" if ctx.context.declined?(name, url: pr["url"])
    return "#{name} was offered already" if ctx.context.offered(name)

    number = pr["number"]
    body = [pr["title"].to_s.gsub(/\s+/, " ").strip, OFFER_LINE].reject(&:empty?).join("\n\n")
    ctx.card(id: offer_card_id(number), title: "PR ##{number} for branch #{branch}", body: body, level: :info,
             actions: [{ label: "Attach", command: "/pr-attach #{number}" },
                       { label: "Not here", command: "/pr-decline #{number}" }])
    ctx.context.mark_offered(name, pr["url"], why: "branch #{branch} has open PR ##{number}")
    offers_log(ctx).write("offered", session: ctx.session_id, project_root: project_root(ctx), cwd: ctx.cwd,
                                     branch: branch, pr: pr["url"], checkout: checkout_kind(ctx), model: ctx.model)
    "offered #{name}"
  end

  # /pr-attach and /pr-decline: the PR number and its offer, else the
  # answer (a usage line, no offer).
  def offer_command(command, args, ctx)
    number = args.to_s.strip[PR_NUMBER, 1] or return "usage: #{command} <PR number>, as the offer card names it"
    number = number.to_i
    offer = ctx.context.offered("pr-#{number}")
    return "no offered PR ##{number} here; use `chi context add <PR URL>`" unless offer

    yield number, offer
  rescue Samagotchi::Plugin::AttachedContext::Error => e
    "pr-#{number} not changed: #{e.message}"
  end

  # The user's click: attached as auto-attach would, past a decline, with
  # the offer's why (no git or gh here).
  def attach_offered(ctx, number, offer)
    why = "#{offer.why || "open PR ##{number}"} (attached from the offer)"
    attached = ctx.context.attach(url: offer.hint, name: offer.name, why: why, force: true)
    return "#{offer.name} wasn't attached" unless attached

    ctx.card(id: offer_card_id(number), title: "PR ##{number}", body: "Attached #{attached}")
    offers_log(ctx).write("attached", session: ctx.session_id, pr: offer.hint, seconds: seconds_since(offer))
    nil
  end

  # Not for a PR attached here already (a stale card): that is
  # `chi context rm`'s, and a declined marker would leave it attached.
  def decline_offered(ctx, number, offer)
    attached = ctx.context.list.find { |source| source[:name] == offer.name || source[:hint] == offer.hint }
    return "#{attached[:name]} is attached here; `chi context rm #{attached[:name]}` removes it" if attached

    ctx.context.decline(url: offer.hint, name: offer.name)
    ctx.card(id: offer_card_id(number), title: "PR ##{number}", body: "Not attached here; + URL attaches it")
    offers_log(ctx).write("declined", session: ctx.session_id, pr: offer.hint, seconds: seconds_since(offer))
    nil
  end

  def seconds_since(offer)
    (Time.now - Time.iso8601(offer.at.to_s)).round
  rescue ArgumentError
    nil
  end

  # Offer mode: every session's first prompt (offered or not; a web chat's
  # first turn starts before the init task's gh returns), joined to the
  # offers by session at analysis time. First = no user message yet (a
  # context note may be in messages already); a fork starts from its
  # parent's conversation, user messages and all, so its first is the one
  # the log has no first_prompt row for yet.
  def log_first_prompt(event, ctx)
    return if event[:prompt].nil? || auto_attach_mode(ctx) != :offer
    return if ctx.scratch? || ctx.session_id.nil?

    log = offers_log(ctx)
    if Array(event[:messages]).any? { |message| message_role(message) == "user" }
      return unless ctx.fork? && !log.first_prompt?(ctx.session_id)
    elsif ctx.delegate?
      return
    end
    log.write("first_prompt", session: ctx.session_id, prompt: event[:prompt].to_s[0, FIRST_PROMPT_CHARS])
  rescue StandardError => e
    ctx.log.debug(:pr_offers_log_failed, error: e.class.name)
  end

  def message_role(message)
    return nil unless message.is_a?(Hash)

    (message.key?(:role) ? message[:role] : message["role"]).to_s
  end

  def offers_log(ctx) = OffersLog.new(File.join(ctx.data_dir, OffersLog::FILE), ctx.log)

  def project_root(ctx)
    ctx.repo_root
  rescue StandardError
    nil
  end

  # "main" for the main checkout, "worktree" for a linked one (its git dir
  # isn't the common one), nil outside a repo.
  def checkout_kind(ctx)
    dirs = run(ctx, "git", "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir").to_s.split("\n")
    return nil unless dirs.size == 2

    dirs[0] == dirs[1] ? "main" : "worktree"
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
    return unless line_links?(ctx)
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

# <data_dir>/offers.ndjson: one JSON object a line, {event:, ts:, …},
# private to the user (0600: it holds prompts). Every worker shares it, so
# each write holds offers.ndjson.lock (flock) around the size check, the
# rotation and the append; over MAX_BYTES the file becomes
# offers.ndjson.1 (one old file kept). A failure is logged at debug: the
# log never breaks an attach.
class OffersLog
  FILE = "offers.ndjson"
  MAX_BYTES = 1024 * 1024
  LINE_MAX_BYTES = 4000
  MODE = 0o600

  def initialize(path, log)
    @path = path
    @log = log
  end

  def write(event, **fields)
    line = "#{JSON.generate({ event: event, ts: Time.now.utc.iso8601 }.merge(fields))}\n"
    return @log.debug(:pr_offers_line_too_long, event: event) if line.bytesize > LINE_MAX_BYTES

    File.open("#{@path}.lock", File::RDWR | File::CREAT, MODE) do |lock|
      lock.flock(File::LOCK_EX)
      File.rename(@path, "#{@path}.1") if File.size?(@path).to_i > MAX_BYTES
      File.open(@path, File::WRONLY | File::APPEND | File::CREAT, MODE) { |file| file.write(line) }
    end
    nil
  rescue StandardError => e
    @log.debug(:pr_offers_log_failed, error: e.class.name)
    nil
  end

  # Whether the log (or its old file) has session +id+'s first_prompt row.
  def first_prompt?(id)
    [@path, "#{@path}.1"].any? do |path|
      File.exist?(path) && File.foreach(path).any? do |line|
        line.include?(%("session":#{JSON.generate(id)})) && JSON.parse(line)["event"] == "first_prompt"
      rescue JSON::ParserError
        false
      end
    end
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

  # @param prs [Array<Array(PrRef, PrData)>]
  def initialize(prs)
    @prs = prs
  end

  # +text+ with each ref that names exactly one PR's file as a markdown
  # link; the part beyond MAX_SCAN stays as it is.
  def link(text)
    head = text[0, MAX_SCAN]
    out = +""
    pos = 0
    hits(head).each do |start, finish, url|
      out << head[pos...start] << "[#{head[start...finish]}](#{url})"
      pos = finish
    end
    return text if pos.zero?

    out << head[pos..] << text[MAX_SCAN..].to_s
  end

  # The URL for +path+'s lines +from+..+to+ (+to+ nil: one line), or nil:
  # no PR has the file, or more than one does.
  def url_for(path, from, to = nil)
    found = @prs.filter_map do |pr, data|
      file = resolve(data.files, path)
      [pr, data, file] if file
    end
    return nil unless found.size == 1

    line_url(*found.first, from, to)
  end

  private

  # [start, finish, url] for each ref to link, by offset.
  def hits(text)
    fences = fenced_blocks(text)
    skipped = fences + spans(text, URL_SPAN) + spans(text, MARKDOWN_LINK)
    code = inline_code(text, fences)
    found = []
    code.each do |start, finish, inner|
      next if inside_any?(skipped, start, finish)

      match = inner.strip.match(REF_ALONE) or next
      url = ref_url(match) and found << [start, finish, url]
    end
    text.scan(REF) do
      match = Regexp.last_match
      start = match.begin(0)
      finish = match.end(0)
      next if inside_any?(skipped, start, finish) || inside_any?(code, start, finish)

      url = ref_url(match) and found << [start, finish, url]
    end
    found.sort_by(&:first)
  end

  # A path has a `/` or an extension (`10:30` is a time, `host:8080` a port).
  def ref_url(match)
    path = match[:path]
    return nil unless path.include?("/") || path.match?(/\.[A-Za-z0-9]+\z/)

    from = match[:from].to_i
    to = match[:to]&.to_i
    to = nil if to && to <= from
    from.zero? ? nil : url_for(path, from, to)
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
  # (a removed one: at its base), which has every line.
  def line_url(pr, data, file, from, to)
    last = to || from
    hunks, side = file.removed? ? [file.old_hunks, "L"] : [file.new_hunks, "R"]
    if hunks.any? { |hunk| hunk.cover?(from) && hunk.cover?(last) }
      anchor = "#{side}#{from}#{"-#{side}#{to}" if to}"
      return "#{pr.url}/files#diff-#{Digest::SHA256.hexdigest(file.path)}#{anchor}"
    end

    sha = file.removed? ? data.base_sha : data.head_sha
    path = file.path.split("/").map { |segment| segment.gsub(/[^\w.~-]/) { |c| c.bytes.map { |b| format("%%%02X", b) }.join } }
    "https://github.com/#{pr.owner}/#{pr.repo}/blob/#{sha}/#{path.join("/")}#L#{from}#{"-L#{to}" if to}"
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
