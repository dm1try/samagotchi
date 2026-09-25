# frozen_string_literal: true

# A before_tool_call guard against near-misses of protected identifiers in
# a tool call's command or paths: the user's home folder name, login, git
# name and email, the repo name, and any names from config. A local model
# that once misspelled a name in a path keeps copying the wrong spelling;
# a rejection that names the right one breaks the loop.
#
# Settings (config.yml, `bundles: known-names:`), all optional:
#   names: [dzmitrydziadou]      names to protect besides the derived ones
#   mode: reject                 reject (default) | correct | ask
#   derive: [home, user, git, repo]   which names to derive (default all)
#   ignore: [dmitri]             names never to protect (a real near name)
#   min_length: 6                shorter names and tokens are skipped
#   max_distance: 2              edits allowed; default 1 for a name under
#                                10 characters, 2 otherwise
class KnownNames
  MODES = %w[reject ask correct].freeze
  DERIVATIONS = %w[home user git repo].freeze
  DEFAULT_MIN_LENGTH = 6
  # Splits a command or path into tokens; each token's [-_.] parts are
  # candidates too.
  TOKEN_SPLIT = %r{[/\s"'=:,;|&()<>@]+}.freeze
  PART_SPLIT = /[-_.]+/.freeze
  ASK_OPTIONS = ["Correct it and run", "Run as is", "Deny"].freeze

  def initialize(settings = {})
    settings = {} unless settings.is_a?(Hash)
    @names = list(settings["names"])
    @ignore = list(settings["ignore"]).map(&:downcase)
    @mode = MODES.include?(settings["mode"].to_s) ? settings["mode"].to_s : "reject"
    derive = settings.key?("derive") ? list(settings["derive"]) & DERIVATIONS : DERIVATIONS
    @derive = derive
    @min_length = [settings["min_length"].to_i, 1].max
    @min_length = DEFAULT_MIN_LENGTH if settings["min_length"].nil?
    max = settings["max_distance"].to_i
    @max_distance = max.positive? ? max : nil
    @git_cache = {}
  end

  def call(event)
    return unless event.is_a?(Hash) && event[:type] == :before_tool_call

    hit = find_near_miss(event)
    return unless hit

    case @mode
    when "correct" then correct(event, hit)
    when "ask" then ask(event, hit)
    else reject(event, hit)
    end
  rescue StandardError => e
    event[:notify]&.call("known-names failed: #{e.class}: #{e.message}", level: :warn)
  end

  # Damerau-Levenshtein distance (optimal string alignment: an adjacent
  # transposition counts as one edit).
  def self.distance(a, b)
    a = a.to_s
    b = b.to_s
    return b.length if a.empty?
    return a.length if b.empty?

    prev2 = nil
    prev = (0..b.length).to_a
    a.each_char.with_index(1) do |ca, i|
      row = [i]
      b.each_char.with_index(1) do |cb, j|
        cost = ca == cb ? 0 : 1
        best = [prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost].min
        if i > 1 && j > 1 && ca == b[j - 2] && a[i - 2] == cb
          best = [best, prev2[j - 2] + 1].min
        end
        row << best
      end
      prev2 = prev
      prev = row
    end
    prev.last
  end

  private

  # The first candidate that is a near miss of a known name.
  # @return [Hash, nil] {miss:, name:, distance:, where:}
  def find_near_miss(event)
    names = known_names(event)
    return nil if names.empty?

    scan_targets(event).each do |where, text|
      candidates(text).each do |candidate|
        down = candidate.downcase
        next if names.key?(down)

        names.each do |name_down, name|
          max = @max_distance || (name.length < 10 ? 1 : 2)
          next if (candidate.length - name.length).abs > max

          d = self.class.distance(down, name_down)
          return { miss: candidate, name: name, distance: d, where: where } if d.between?(1, max)
        end
      end
    end
    nil
  end

  # [where, text] pairs to scan: the command, the cwd a command names,
  # each path, and a write/edit call's own path (in case normalisation
  # dropped it). Not file contents.
  def scan_targets(event)
    targets = event[:targets].is_a?(Hash) ? event[:targets] : {}
    call = event[:call].is_a?(Hash) ? event[:call] : {}
    pairs = []
    pairs << ["command", targets[:command].to_s] unless targets[:command].to_s.empty?
    pairs << ["cwd", call[:cwd].to_s] unless call[:cwd].to_s.strip.empty?
    Array(targets[:paths]).each { |path| pairs << ["path", path.to_s] }
    pairs << ["path", call[:path].to_s] if %w[write edit].include?(call[:name].to_s) && !call[:path].to_s.empty?
    pairs
  end

  def candidates(text)
    text.split(TOKEN_SPLIT).flat_map { |token| [token] + token.split(PART_SPLIT) }
        .uniq.select { |c| c.length >= @min_length }
  end

  # downcased name => name as given, minus ignored and short ones
  def known_names(event)
    names = @names + derived_names(event)
    names.each_with_object({}) do |name, acc|
      next if name.length < @min_length
      down = name.downcase
      next if @ignore.include?(down) || acc.key?(down)

      acc[down] = name
    end
  end

  def derived_names(event)
    names = []
    names << File.basename(Dir.home) if @derive.include?("home")
    names << ENV["USER"].to_s if @derive.include?("user")
    context = event[:context].is_a?(Hash) ? event[:context] : {}
    root = context[:repo_root].to_s
    names << File.basename(root) if @derive.include?("repo") && !root.empty?
    names.concat(git_names(root)) if @derive.include?("git") && !root.empty?
    names.map(&:to_s).map(&:strip).reject(&:empty?)
  rescue StandardError
    names
  end

  # The words of git's user.name and the local part of user.email, one
  # git call per repo root.
  def git_names(root)
    @git_cache[root] ||= begin
      name = git_config(root, "user.name")
      email = git_config(root, "user.email")
      name.split(/\s+/) + [email.split("@").first.to_s]
    end
  end

  def git_config(root, key)
    IO.popen(["git", "-C", root, "config", "--get", key], err: File::NULL, &:read).to_s.strip
  rescue StandardError
    ""
  end

  def reject(event, hit)
    tool = event[:call].is_a?(Hash) ? event[:call][:name] : nil
    edits = hit[:distance] == 1 ? "1 edit" : "#{hit[:distance]} edits"
    event[:guardrail]&.deny!(
      "\"#{hit[:miss]}\" in the #{hit[:where]} is #{edits} away from the known name \"#{hit[:name]}\"",
      source: "hook known_names, bundle known-names",
      advice: "Retry with \"#{hit[:name]}\". If \"#{hit[:miss]}\" is really what you meant, say so to the user instead of retrying."
    )
    event[:notify]&.call("rejected #{tool}: \"#{hit[:miss]}\" looks like \"#{hit[:name]}\"")
  end

  # The same call with the near miss replaced (whole tokens, everywhere it
  # appears in the content, path and cwd).
  def correct(event, hit)
    call = event[:call]
    pattern = /(?<![A-Za-z0-9])#{Regexp.escape(hit[:miss])}(?![A-Za-z0-9])/
    fixed = call.dup
    %i[content path cwd].each do |key|
      next unless fixed[key].is_a?(String)

      fixed[key] = fixed[key].gsub(pattern, hit[:name])
    end
    event[:call] = fixed
    event[:notify]&.call("corrected \"#{hit[:miss]}\" → \"#{hit[:name]}\" in #{call[:name]}")
  end

  def ask(event, hit)
    tool = event[:call].is_a?(Hash) ? event[:call][:name] : nil
    answer = event[:ask_user]&.call(
      question: "#{tool}: #{event[:params]}\n\"#{hit[:miss]}\" looks like a misspelling of \"#{hit[:name]}\".",
      options: ASK_OPTIONS, header: "known-names"
    )
    choice = answer.is_a?(Hash) ? Array(answer[:selected]).first.to_s : ""
    case choice
    when ASK_OPTIONS[0] then correct(event, hit)
    when ASK_OPTIONS[1] then nil
    else reject(event, hit)
    end
  end

  def list(value)
    Array(value).map(&:to_s).map(&:strip).reject(&:empty?)
  end
end
