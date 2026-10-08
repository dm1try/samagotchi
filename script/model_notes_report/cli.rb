# frozen_string_literal: true

require "json"
require "optparse"
require "time"
require_relative "report"

module ModelNotesReport
  # script/model_notes_report.rb: reads a sessions folder, groups the
  # sessions by model and the model notes their prompt carried
  # (prompt_notes), and reports each session's and group's numbers
  # (SessionStats says how each is read). Reads only; prints only ids,
  # model names, note names and digests, dates and numbers.
  class CLI
    Options = Struct.new(:dir, :models, :since, :min_steps, :json, keyword_init: true)

    DEFINITIONS = <<~TEXT
      Metrics (per session; a group has the medians of the places and runs, commits/100 pooled, the rest summed):
        steps        model entries (requests), as the step limit counts them
        calls        tool calls, in order (a native model's read from its text)
        1st-edit     the place (1-based, among the calls) of the first edit or write call
        1st-commit   the place of the first execute call that runs git [options] commit
        commits/100  commits per 100 steps
        no-edit      the most calls in a row with no edit or write
        bare&        execute calls with a background & (not &&, 2>&1, &> or a quoted one)
        cont         turns with no prompt of their own (a step-limit Continue; also a reminder's turn),
                     from <dir>/<id>/analytics.json; - without it
        steer        user lines that reached a running turn (the user's, chi send's, a parent's) and the
                     steers a person sent (a Continue's text)
        f-up         user prompts after the first that started a turn (not a delegate report's wake)
        nudge        the other steers (a plugin's, such as the loop guard)
      Groups: the model name as saved, and the prompt_notes as name@digest ("none" without any, or in a
      file from before they were recorded; a /model switch records the new model's).
    TEXT

    def initialize(argv, env: ENV, out: $stdout, err: $stderr)
      @argv = argv.dup
      @env = env
      @out = out
      @err = err
    end

    # @return [Integer] 0, or 2 for a usage error
    def run
      options = parse
      return 2 unless options

      unless File.directory?(options.dir)
        @err.puts "model_notes_report: no sessions directory #{options.dir}"
        return 2
      end

      report = build(options)
      @out.puts(options.json ? JSON.pretty_generate(report.to_h) : report.text)
      0
    end

    private

    def parse
      options = Options.new(models: nil, since: nil, min_steps: 1, json: false)
      parser = OptionParser.new do |o|
        o.banner = "usage: script/model_notes_report.rb [options]"
        o.on("--sessions DIR", "a folder of <session id>.json files (default chi's own)") { |dir| options.dir = dir }
        o.on("--model GLOB", "only models matching GLOB (fnmatch, any case; `|` between several), on the " \
                             "saved name or without its host prefix") do |glob|
          options.models = Samagotchi::ModelMatch.parse(glob)
        end
        o.on("--since DATE", "only sessions created on or after DATE (ISO 8601)") do |date|
          options.since = Time.iso8601(date.include?("T") ? date : "#{date}T00:00:00Z")
        rescue ArgumentError
          raise OptionParser::InvalidArgument, date
        end
        o.on("--min-steps N", Integer, "only sessions with at least N steps (default 1)") { |n| options.min_steps = n }
        o.on("--json", "JSON instead of tables") { options.json = true }
        o.separator ""
        o.separator DEFINITIONS
      end
      rest = parser.parse(@argv)
      raise OptionParser::NeedlessArgument, rest.join(" ") unless rest.empty?

      options.dir = File.expand_path(options.dir || Samagotchi::Session.default_state_dir(env: @env))
      options
    rescue OptionParser::ParseError => e
      @err.puts "model_notes_report: #{e.message}\n#{parser}"
      nil
    end

    def build(options)
      skipped = { unreadable: 0, other_model: 0, older: 0, few_steps: 0 }
      sessions = Dir.glob(File.join(options.dir, "*.json")).sort.filter_map do |path|
        stats = read(path)
        reason = stats ? skip_reason(stats, options) : :unreadable
        skipped[reason] += 1 if reason
        stats unless reason
      end
      Report.new(source: options.dir, sessions: sessions, skipped: skipped)
    end

    def read(path)
      SessionReader.read(path)
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError, NoMethodError, SystemCallError
      nil
    end

    def skip_reason(stats, options)
      if options.models && !model_match?(options.models, stats.model) then :other_model
      elsif options.since && !since?(stats, options.since) then :older
      elsif stats.steps < options.min_steps then :few_steps
      end
    end

    # The saved name ("openrouter:deepseek/…") or the name without its host
    # prefix ("deepseek/…").
    def model_match?(globs, model)
      bare = model.sub(%r{\A[\w.-]+:(?=[^\s:]*/)}, "")
      globs.any? { |glob| Samagotchi::ModelMatch.glob?(glob, name: model, key: bare) }
    end

    def since?(stats, since)
      Time.iso8601(stats.created_at) >= since
    rescue ArgumentError
      false
    end
  end
end
