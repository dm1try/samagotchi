# frozen_string_literal: true

require "json"
require "optparse"
require_relative "report"

module LLMContextBench
  # script/llm_context_bench.rb: replays stored sessions offline and
  # reports, per strategy × model × policy, what each would have changed
  # (docs/internals/llm-context-bench.md). Reads only the sessions
  # directory it is given; never calls a model.
  class CLI
    ENV_DIR = "LLM_CONTEXT_BENCH_SESSIONS"
    DEFAULT_STRATEGIES = %w[none forget_all].freeze

    Options = Struct.new(:dir, :strategies, :picks, :cases_file, :min_turn_tool, :top, :sessions, :profile, :per_case,
                         :json, keyword_init: true)

    def initialize(argv, env: ENV, out: $stdout, err: $stderr)
      @argv = argv.dup
      @env = env
      @out = out
      @err = err
    end

    # @return [Integer] the exit status
    def run
      options = parse
      return 2 unless options

      unless File.directory?(options.dir)
        @err.puts "llm_context_bench: no sessions directory #{options.dir}"
        return 2
      end
      report = build(options)
      @out.puts(options.json ? JSON.pretty_generate(report.to_h) : report.text(per_case: options.per_case))
      0
    end

    private

    def parse
      options = Options.new(strategies: DEFAULT_STRATEGIES.dup, picks: [], min_turn_tool: Cases::MIN_TURN_TOOL,
                            profile: true, per_case: false, json: false)
      parser = OptionParser.new do |o|
        o.banner = "usage: script/llm_context_bench.rb [SESSIONS_DIR] [options]\n  " \
                   "SESSIONS_DIR: a folder of <session id>.json files (default $#{ENV_DIR}, else chi's own)"
        o.on("--strategy LIST", "strategies, comma-separated: #{Strategies.names.join(", ")} (default none,forget_all)") do |list|
          options.strategies = list.split(",").map(&:strip)
        end
        o.on("--picks LABEL=DIR", "recorded model picks to score (repeatable)") do |spec|
          label, dir = spec.split("=", 2)
          options.picks << [label, dir || label]
        end
        o.on("--cases FILE", "case names, one per line (<id8>_t<N>)") { |path| options.cases_file = path }
        o.on("--min-turn-tool N", Integer, "a case's turn holds at least N tool tokens (default #{Cases::MIN_TURN_TOOL})") do |n|
          options.min_turn_tool = n
        end
        o.on("--top N", Integer, "only the N heaviest sessions") { |n| options.top = n }
        o.on("--session PREFIX", "only sessions whose id starts so (repeatable)") { |prefix| (options.sessions ||= []) << prefix }
        o.on("--[no-]profile", "the none profile (default on)") { |on| options.profile = on }
        o.on("--per-case", "a row per case too") { options.per_case = true }
        o.on("--json", "JSON instead of text") { options.json = true }
      end
      rest = parser.parse(@argv)
      options.dir = File.expand_path(rest.first || @env[ENV_DIR] || Samagotchi::Session.default_sessions_dir)
      options
    rescue OptionParser::ParseError => e
      @err.puts "llm_context_bench: #{e.message}\n#{parser}"
      nil
    end

    def build(options)
      replays = Replay.from_dir(options.dir, top: options.top, only: options.sessions)
      picks = options.picks.map { |label, dir| Strategies::Picks.new(label: label, dir: File.expand_path(dir)) }
      cases = Cases.select(replays, names: case_names(options, picks), min_turn_tool: options.min_turn_tool)
      results = []
      skipped = {}
      options.strategies.each do |name|
        strategy = Strategies.build(name)
        results.concat(score(strategy, cases))
      rescue NotBuilt => e
        skipped[name] = e.message
      end
      picks.each { |source| results.concat(score(source, cases)) }
      Report.new(results: results, profile: (Profile.new(replays) if options.profile), skipped: skipped,
                 sessions: replays.size, source: options.dir)
    end

    def score(strategy, cases)
      scorer = Scorer.new
      cases.flat_map { |kase| strategy.plans(kase) }.map { |plan| scorer.score(plan) }
    end

    # The cases a --cases file names, else those the picks have, else nil
    # (the turn-size rule).
    def case_names(options, picks)
      return Cases.read_names(options.cases_file) if options.cases_file
      return picks.flat_map(&:case_names).uniq unless picks.empty?

      nil
    end
  end
end
