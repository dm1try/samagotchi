# frozen_string_literal: true

# A GitHub PR as attached context (chi context; docs/context.md): run by
# chi as `{ruby} pr_context.rb <url>`, it prints the JSON contract
# {text, summary, wake}. +text+ is the PR (title, state, description,
# reviews, comments oldest first, checks); +summary+ says what changed
# since the last text chi has (SAMAGOTCHI_CONTEXT_PREVIOUS) in counts,
# authors and states only, never a comment's or review's words: the summary
# reaches the model in the update note without a read, and those words are
# third-party text. +wake+ asks chi to start a turn for a review requesting
# changes, checks turning red, or the PR closed or merged; comments alone
# never do (D9).
#
# Plain Ruby (json, open3) and `gh`, nothing from chi; the provider runs it
# with chi's own Ruby ({ruby}), not whichever `ruby` is on the PATH.

require "json"
require "open3"

module PrContext
  FIELDS = "number,url,title,state,isDraft,body,author,headRefName,baseRefName,reviews,comments,statusCheckRollup"
  FAILING = %w[FAILURE ERROR TIMED_OUT CANCELLED ACTION_REQUIRED STARTUP_FAILURE].freeze
  PASSING = %w[SUCCESS NEUTRAL SKIPPED].freeze
  REVIEW_WORDS = { "CHANGES_REQUESTED" => "changes requested", "APPROVED" => "approved", "COMMENTED" => "commented",
                   "DISMISSED" => "dismissed" }.freeze
  TITLE_MAX = 80

  # What a text says, read back from it: the PR's state, its comments and
  # reviews (author, time[, state]) and its checks (name → result).
  Facts = Struct.new(:state, :comments, :reviews, :checks, keyword_init: true) do
    def failing = checks.count { |_name, result| result == "failing" }
    def pending = checks.count { |_name, result| result == "pending" }
  end

  module_function

  def main(argv, env: ENV, out: $stdout, err: $stderr)
    url = argv.first.to_s
    if url.empty?
      err.puts("usage: pr_context.rb <pull request URL>")
      return 2
    end

    json, error, status = Open3.capture3("gh", "pr", "view", url, "--json", FIELDS)
    unless status.success?
      err.puts(error.strip.empty? ? "gh pr view failed" : error.strip.lines.last.strip)
      return 1
    end

    out.puts(JSON.generate(contract(JSON.parse(json), previous_text(env["SAMAGOTCHI_CONTEXT_PREVIOUS"]))))
    0
  rescue Errno::ENOENT
    err.puts("gh isn't installed (https://cli.github.com)")
    1
  end

  # @return [Hash] {text, summary, wake}
  def contract(pr, previous)
    text = render(pr)
    now = facts(text)
    if previous
      summary, wake = changes(facts(previous), now)
      { "text" => text, "summary" => summary, "wake" => wake }
    else
      { "text" => text, "summary" => overview(pr, now), "wake" => false }
    end
  end

  def previous_text(path)
    return nil if path.to_s.empty? || !File.file?(path)

    data = JSON.parse(File.read(path))
    data.is_a?(Hash) && data["text"].is_a?(String) ? data["text"] : nil
  rescue JSON::ParserError, SystemCallError
    nil
  end

  # The PR as text. Every line a person wrote (description, reviews,
  # comments) is indented, so no body can pass for one of the header lines
  # #facts reads back.
  def render(pr)
    lines = ["PR ##{pr["number"]}: #{pr["title"]}", "URL: #{pr["url"]}", "State: #{state_of(pr)}",
             "Branch: #{pr["headRefName"]} -> #{pr["baseRefName"]}", "Author: @#{login(pr["author"])}", "",
             "## Description", indent(pr["body"]), ""]
    reviews = Array(pr["reviews"])
    lines << "## Reviews (#{reviews.size})"
    reviews.each do |review|
      lines << "- @#{login(review["author"])}: #{review["state"]}, #{review["submittedAt"]}"
      lines << indent(review["body"]) unless review["body"].to_s.strip.empty?
    end
    comments = Array(pr["comments"])
    lines += ["", "## Comments (#{comments.size})"]
    comments.each do |comment|
      lines << "- @#{login(comment["author"])}, #{comment["createdAt"]}:"
      lines << indent(comment["body"])
    end
    checks = Array(pr["statusCheckRollup"])
    lines += ["", "## Checks (#{checks.size})"]
    checks.each { |check| lines << "- #{check_name(check)}: #{check_result(check)}" }
    "#{lines.join("\n")}\n"
  end

  def state_of(pr)
    state = pr["state"].to_s
    state == "OPEN" && pr["isDraft"] ? "OPEN (draft)" : state
  end

  def login(author) = (author.is_a?(Hash) ? author["login"] : nil) || "ghost"

  def indent(text)
    body = text.to_s.strip
    body.empty? ? "  (empty)" : body.lines.map { |line| "  #{line.chomp}" }.join("\n")
  end

  def check_name(check) = (check["name"] || check["context"] || "check").to_s.tr("\n", " ")

  # passing, failing or pending, from a CheckRun's status/conclusion or a
  # StatusContext's state.
  def check_result(check)
    value = (check["conclusion"].to_s.empty? ? check["state"] : check["conclusion"]).to_s.upcase
    return "pending" if value.empty? || %w[PENDING EXPECTED QUEUED IN_PROGRESS].include?(value)
    return "failing" if FAILING.include?(value)

    PASSING.include?(value) ? "passing" : "pending"
  end

  # Reads #render's header lines back (lines at column 0 only).
  def facts(text)
    section = nil
    found = Facts.new(state: nil, comments: [], reviews: [], checks: {})
    text.each_line(chomp: true) do |line|
      next if line.start_with?(" ")

      if (m = line.match(/\AState: (\S+)/)) then found.state = m[1]
      elsif (m = line.match(/\A## (\w+)/)) then section = m[1]
      elsif section == "Comments" && (m = line.match(/\A- @(\S+), (\S+):\z/)) then found.comments << [m[1], m[2]]
      elsif section == "Reviews" && (m = line.match(/\A- @(\S+): (\w+), (\S*)\z/)) then found.reviews << [m[1], m[2], m[3]]
      elsif section == "Checks" && (m = line.match(/\A- (.+): (passing|failing|pending)\z/)) then found.checks[m[1]] = m[2]
      end
    end
    found
  end

  # The first summary: title (cut), state, counts, checks.
  def overview(pr, now)
    title = pr["title"].to_s.strip
    title = "#{title[0, TITLE_MAX - 1]}…" if title.length > TITLE_MAX
    parts = ["\"#{title}\"", now.state.to_s.downcase, count(now.comments.size, "comment"), count(now.reviews.size, "review")]
    parts << "checks #{checks_word(now)}" unless now.checks.empty?
    parts.join(", ")
  end

  # @return [Array(String, Boolean)] what changed, and whether it wakes
  def changes(before, now)
    parts = []
    wake = false
    if before.state != now.state
      parts << "PR #{now.state.to_s.downcase}"
      wake = true if before.state.to_s.start_with?("OPEN") && %w[CLOSED MERGED].include?(now.state)
    end
    fresh_comments = now.comments - before.comments
    unless fresh_comments.empty?
      parts << "#{count(fresh_comments.size, "new comment")} (#{authors(fresh_comments.map(&:first))})"
    end
    fresh_reviews = now.reviews - before.reviews
    fresh_reviews.group_by { |_author, state, _at| state }.each do |state, reviews|
      parts << "review: #{REVIEW_WORDS.fetch(state, state.downcase)} by #{authors(reviews.map(&:first))}"
      wake = true if state == "CHANGES_REQUESTED"
    end
    if before.checks != now.checks && !now.checks.empty?
      parts << "checks: #{checks_word(now)}"
      wake = true if before.failing.zero? && now.failing.positive?
    end
    parts << "updated (title, description or branch)" if parts.empty?
    [parts.join("; "), wake]
  end

  def checks_word(facts)
    return "#{facts.failing} failing" if facts.failing.positive?
    return "#{facts.pending} pending" if facts.pending.positive?

    "passing"
  end

  def count(number, word) = "#{number} #{word}#{"s" unless number == 1}"

  def authors(logins) = logins.uniq.map { |login| "@#{login}" }.join(", ")
end

exit(PrContext.main(ARGV)) if $PROGRAM_NAME == __FILE__
