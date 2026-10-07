# frozen_string_literal: true

require "json"
require "optparse"
require_relative "report"
require_relative "live_pick"

module LLMContextBench
  # script/llm_context_bench.rb: replays stored sessions offline and
  # reports, per strategy × model × policy, what each would have changed
  # (docs/internals/llm-context-bench.md). Reads only the sessions
  # directory it is given; calls a model only with --live (LivePick), which
  # saves picks for a later offline run to score (--picks).
  class CLI
    ENV_DIR = "LLM_CONTEXT_BENCH_SESSIONS"
    DEFAULT_STRATEGIES = %w[none forget_all].freeze

    Options = Struct.new(:dir, :strategies, :picks, :cases_file, :min_turn_tool, :top, :sessions, :profile, :per_case,
                         :json, :live, :tool_name, :policy, :out_dir, :samples, :dry_run, :layout, :force,
                         :ends, keyword_init: true)

    # @param chat_adapter [#call] model ref => [adapter, bare model], for
    #   --live (LivePick.chat_adapter; a spec points it at a fake server)
    def initialize(argv, env: ENV, out: $stdout, err: $stderr, chat_adapter: LivePick.method(:chat_adapter))
      @chat_adapter = chat_adapter
      @argv = argv.dup
      @env = env
      @out = out
      @err = err
    end

    # @return [Integer] the exit status: 0, 2 for a usage error, 1 when a
    #   --live run stopped on a payment error
    def run
      options = parse
      return 2 unless options

      unless File.directory?(options.dir)
        @err.puts "llm_context_bench: no sessions directory #{options.dir}"
        return 2
      end
      return live(options) if options.live

      report = build(options)
      @out.puts(options.json ? JSON.pretty_generate(report.to_h) : report.text(per_case: options.per_case))
      0
    end

    private

    def parse
      options = Options.new(strategies: DEFAULT_STRATEGIES.dup, picks: [], min_turn_tool: Cases::MIN_TURN_TOOL,
                            profile: true, per_case: false, json: false, tool_name: LivePick::TOOL_NAMES.first,
                            policy: "subtask", samples: 1, dry_run: false, layout: LivePick::LAYOUTS.first, force: true)
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
        o.on("--ends RULE", Cases::ENDS, "which turn ends make cases: answer (the model's final answer) or any " \
                                         "(default answer for the turn-size rule, any for named cases)") do |rule|
          options.ends = rule
        end
        o.on("--top N", Integer, "only the N heaviest sessions") { |n| options.top = n }
        o.on("--session PREFIX", "only sessions whose id starts so (repeatable)") { |prefix| (options.sessions ||= []) << prefix }
        o.on("--[no-]profile", "the none profile (default on)") { |on| options.profile = on }
        o.on("--per-case", "a row per case too") { options.per_case = true }
        o.on("--json", "JSON instead of text") { options.json = true }
        o.separator "live picks (calls a model through chi's chat client; for the D7 A/B):"
        o.on("--live MODEL", "ask MODEL (a chi model ref on an api: openai host) to pick, per case") { |ref| options.live = ref }
        o.on("--tool-name NAME", LivePick::TOOL_NAMES, "the forget tool's name (default #{LivePick::TOOL_NAMES.first})") do |name|
          options.tool_name = name
        end
        o.on("--policy NAME", LivePick::POLICIES.keys, "the tail line: #{LivePick::POLICIES.keys.join(", ")} (default subtask)") do |name|
          options.policy = name
        end
        o.on("--layout NAME", LivePick::LAYOUTS, "where the tail line goes: #{LivePick::LAYOUTS.join(", ")} (default tail_system)") do |name|
          options.layout = name
        end
        o.on("--[no-]force", "ask again with the tool forced when the model didn't call it (default on)") do |on|
          options.force = on
        end
        o.on("--out DIR", "where the picks go (required with --live)") { |dir| options.out_dir = dir }
        o.on("--samples N", Integer, "picks per case (default 1)") { |n| options.samples = n }
        o.on("--dry-run", "with --live: count the requests and tokens, call nothing") { options.dry_run = true }
      end
      rest = parser.parse(@argv)
      options.dir = File.expand_path(rest.first || @env[ENV_DIR] || Samagotchi::Session.default_sessions_dir)
      options
    rescue OptionParser::ParseError => e
      @err.puts "llm_context_bench: #{e.message}\n#{parser}"
      nil
    end

    def live(options)
      if options.out_dir.nil? && !options.dry_run
        @err.puts "llm_context_bench: --live needs --out DIR"
        return 2
      end
      adapter, model = options.dry_run ? [nil, options.live] : @chat_adapter.call(options.live)
      picker = LivePick.new(adapter: adapter, model: model, tool_name: options.tool_name, policy: options.policy,
                            out_dir: options.out_dir.to_s, samples: options.samples, log: @err, layout: options.layout,
                            force: options.force)
      cases = select_cases(options, Replay.from_dir(options.dir, top: options.top, only: options.sessions),
                           options.cases_file && Cases.read_names(options.cases_file))
      return pick(picker, cases, options.out_dir) unless options.dry_run

      estimate = picker.estimate(cases)
      @out.puts "#{cases.size} case(s) (ending: #{Cases.ends_tally(cases.map(&:ends))}) × #{options.samples} sample(s): #{estimate[:requests]} requests (more if a pick " \
                "is forced), about #{(estimate[:prompt_tokens] / 1000).round}k prompt tokens by chars/4 " \
                "(~#{(estimate[:prompt_tokens] * 1.25 / 1000).round}k as servers count code), the largest " \
                "#{(estimate[:largest] / 1000).round}k"
      0
    end

    def pick(picker, cases, out_dir)
      written = picker.run(cases)
      @out.puts "#{written.size} picks written to #{out_dir} (#{picker.summary}); score them with --picks LABEL=#{out_dir}"
      0
    rescue LivePick::PaymentStop => e
      @err.puts "llm_context_bench: stopped, a payment error: #{e.message}"
      @err.puts "  #{e.written.size} picks written to #{out_dir} before it; a rerun asks only for the rest"
      1
    end

    def build(options)
      replays = Replay.from_dir(options.dir, top: options.top, only: options.sessions)
      picks = options.picks.map { |label, dir| Strategies::Picks.new(label: label, dir: File.expand_path(dir)) }
      cases = select_cases(options, replays, case_names(options, picks))
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
                 sessions: replays.size, source: options.dir, case_ends: cases.to_h { |kase| [kase.name, kase.ends] })
    end

    # The cases to run (Cases.select), saying so when --ends answer drops
    # named ones.
    def select_cases(options, replays, names)
      cases = Cases.select(replays, names: names, min_turn_tool: options.min_turn_tool, ends: options.ends)
      if names && options.ends == "answer"
        dropped = Cases.select(replays, names: names, ends: "any").size - cases.size
        @err.puts "llm_context_bench: --ends answer skipped #{dropped} named case(s) that don't end with an answer" if dropped.positive?
      end
      cases
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
