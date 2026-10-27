# frozen_string_literal: true

require "json"
require "time"

require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "config"
require_relative "session"
require_relative "system_one/log"
require_relative "toolkit"
require_relative "tool_response"
require_relative "toolkit_suggest"

module Samagotchi
  # `chi toolkit report`: compare the toolkit on mode would have run (the
  # suggestion when it would have been applied, else the default) with the
  # tools the session called from that turn on, against every kit's rules
  # the ask logged (ToolkitSuggest.rules).
  class ToolkitReportCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi toolkit report [--days N]
        Grade the kit each audit suggestion would have run (the suggested
        kit when on mode would have applied it, else the default) against
        the tools the session called from that turn on, call_tool targets
        included: covers, short of a tool (named), wider than needed (a
        narrower offered kit would also cover), or ungradable. Then a
        per-kit tally with what on mode would have done. Includes archived
        sessions; the report is limited to 14 days and 500 sessions.
    TEXT

    MAX_DAYS = 14
    MAX_SESSIONS = 500
    FLAGS = CLI::Flags.new(args: false) { |flags| flags.value "--days" }.freeze
    ToolUse = Data.define(:name, :group, :label)

    # @param argv [Array<String>] arguments after "toolkit"
    # @param sessions_dir [String, nil] sessions location (a spec seam)
    # @param log [SystemOne::Log, nil] suggestion log (a spec seam)
    # @param now [Time] the report's clock (a spec seam)
    def initialize(argv, stdout: $stdout, stderr: $stderr, sessions_dir: nil, log: nil, now: Time.now)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @sessions_dir = sessions_dir || Session.default_state_dir
      @log = log
      @now = now
    end

    def run
      @sub = @argv.first
      if @sub.nil? || HELP_WORDS.include?(@sub)
        @stdout.puts(USAGE)
        return CLI::Exit::OK
      end
      return usage_error("unknown subcommand #{@sub}") unless @sub == "report"

      parsed = parse_flags(FLAGS, @argv[1..])
      return parsed if parsed.is_a?(Integer)
      return usage_error("--days takes a positive whole number") if parsed.options[:days] &&
                                                                    !parsed.options[:days].to_s.match?(/\A[1-9]\d*\z/)

      report(parsed.options[:days] ? Integer(parsed.options[:days], 10) : MAX_DAYS)
    end

    private

    def command_name = "chi toolkit report"

    def report(requested_days)
      days = effective_days(requested_days)
      cutoff = @now - (days * 86_400)
      max_sessions = [MAX_SESSIONS, positive_config("session.max_count", MAX_SESSIONS)].min
      sessions = Session.list(state_dir: @sessions_dir, sort: "updated_at", order: "desc",
                              limit: max_sessions, include_archived: true)
      session_summaries = sessions.to_h { |session| [session.id, session] }
      records = log.records.filter_map do |entry|
        next unless entry["kind"] == "suggestion" && session_summaries.key?(entry["session_id"])
        next unless timestamp(entry["at"])&.>= cutoff

        entry
      end
      if records.empty?
        @stdout.puts("No toolkit suggestions in the last #{days} days.")
        return CLI::Exit::OK
      end

      loaded = {}
      tallies = Hash.new { |hash, kit| hash[kit] = Hash.new(0) }
      @stdout.puts("Toolkit suggestions · last #{days} days · up to #{max_sessions} sessions")
      records.sort_by { |entry| timestamp(entry["at"]) }.each do |entry|
        id = entry["session_id"]
        session = loaded[id] ||= Session.load(id, state_dir: @sessions_dir)
        uses, window = window_uses(session, entry["turn_number"].to_i)
        kit = graded_kit(entry)
        grade, detail = grade(entry, kit, uses)
        tallies[kit][grade] += 1
        tallies[kit]["would:#{entry["would"] || "unknown"}"] += 1
        confidence = entry["confidence"].nil? ? "n/a" : format("%.2f", entry["confidence"])
        @stdout.puts("#{timestamp(entry["at"]).iso8601} #{id[0, 8]} turn #{entry["turn_number"]}: " \
                     "#{entry["raw"] || "no judgment"} (p=#{confidence}, would #{entry["would"] || "unknown"}) " \
                     "→ #{kit}: #{grade}#{detail}#{window}")
        labels = uses.is_a?(Array) ? uses.map(&:label).uniq : []
        @stdout.puts("  tools: #{labels.join(", ")}") unless labels.empty?
      rescue StandardError => e
        @stderr.puts("chi toolkit report: session #{id}: #{e.class}: #{e.message}; skipped")
      end
      print_tallies(tallies)
      CLI::Exit::OK
    end

    def log
      @log ||= SystemOne::Log.new(
        dir: File.dirname(ToolkitSuggest.log_path(@sessions_dir)),
        file: ToolkitSuggest::FILE,
        warn: ->(reason) { @stderr.puts("chi toolkit report: #{reason}") }
      )
    end

    def effective_days(requested)
      retention = Config.get("session.retention_days").to_i
      cap = retention.positive? ? [retention, MAX_DAYS].min : MAX_DAYS
      [requested, cap].min
    end

    def positive_config(key, fallback)
      value = Config.get(key).to_i
      value.positive? ? value : fallback
    end

    def timestamp(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # The tools the session called from the suggestion's turn on: to the
    # session's end, or only that turn when the toolkit was chosen since
    # (/toolkit, ctx.use_toolkit: no message marks when, and a change
    # applies from the next turn's start, so the asked turn ran on it).
    # @return [Array(Array<ToolUse>|Symbol, String)] the uses (:ungradable
    #   when a turn's tools can't be read back) and a note on the window
    def window_uses(session, turn_number)
      by_turn = tool_uses_by_turn(session.messages)
      changed = session.toolkit_origin == "chosen"
      turns = by_turn.keys.select { |number| changed ? number == turn_number : number >= turn_number }
      uses = turns.sort.flat_map { |number| by_turn[number] }
      note = changed ? " (its turn only: the toolkit was chosen later)" : ""
      [turns.empty? || uses.include?(:ungradable) ? :ungradable : uses, note]
    end

    # Tool uses grouped by the user's own prompt number; steers and merged
    # input lines remain part of that turn rather than starting another.
    # The chat loop saves its calls on the model's message (tool_calls);
    # the raw-prompt loop saves only the model's text, so its calls are
    # read back from the batch's tool_response entry (#joined_uses).
    def tool_uses_by_turn(messages)
      number = 0
      current = nil
      uses = Hash.new { |hash, key| hash[key] = [] }
      Array(messages).each do |message|
        case field(message, :role).to_s
        when "user"
          if ToolkitSuggest.owner_prompt?(message)
            number += 1
            current = number
            uses[current]
          elsif Steer.participant_author?(field(message, :author))
            current = nil
          end
        when "model"
          Array(field(message, :tool_calls)).each { |call| uses[current] << tool_use(call) } if current
        when "tool_response"
          uses[current].concat(joined_uses(message)) if current && !field(message, :tool_call_id)
        end
      end
      uses.transform_values(&:compact)
    end

    # A ran-as line (ToolRunner, a corrected call) may precede a run's lead.
    RUN_LEAD = /\A(?:ran as: [^\n]*\n)?\[([^\]\s]+)\](?:\n| |\z)/

    # A raw-prompt batch's tools: each run's "[name]" lead (ToolResponse),
    # a call_tool's target from its saved params line ("group/tool …").
    # When the leads don't match the batch's run count, :ungradable.
    def joined_uses(message)
      parts = field(message, :content).to_s.split(ToolResponse::SEPARATOR, -1)
      names = parts.filter_map { |part| part[RUN_LEAD, 1] }
      ids = field(message, :tool_ids)
      return [:ungradable] if names.empty? || (ids.is_a?(Array) && ids.size != names.size)

      params = field(message, :tool_params)
      names.each_with_index.map do |name, index|
        next ToolUse.new(name: name, group: nil, label: name) unless name == "call_tool"

        line = params.is_a?(Array) ? params[index] : nil
        target = line.to_s.split(" ", 2).first.to_s
        next :ungradable unless target.include?("/")

        group, tool = target.split("/", 2)
        ToolUse.new(name: tool, group: group, label: "call_tool→#{target}")
      end
    end

    def tool_use(call)
      return unless call.is_a?(Hash)

      function = field(call, :function)
      name = (field(call, :name) || field(function, :name)).to_s
      arguments = field(call, :arguments) || field(function, :arguments) || field(call, :args)
      arguments = JSON.parse(arguments) if arguments.is_a?(String) && !arguments.empty?
      return ToolUse.new(name: name, group: nil, label: name) unless name == "call_tool"

      target = arguments.is_a?(Hash) ? (field(arguments, :tool) || field(arguments, :name)) : nil
      return :ungradable unless target

      parts = target.to_s.split("/", 2)
      group, tool = parts.size == 2 ? parts : [nil, parts.first]
      ToolUse.new(name: tool, group: group, label: "call_tool→#{target}")
    rescue JSON::ParserError
      name == "call_tool" ? :ungradable : ToolUse.new(name: name, group: nil, label: name)
    end

    # The kit on mode would have run: the suggestion only when it would
    # have been applied, else the session's default.
    def graded_kit(entry)
      name = entry["would"] == "suggested" ? entry["kit"] : entry["default_kit"]
      name || "(unknown)"
    end

    # covers: the kit declares every tool the window used (pick ⊇ need);
    # wider than needed: it covers, and so would a narrower logged kit;
    # short of a tool: names what it leaves out. ungradable when the
    # window's calls or the kit's rules can't be read.
    def grade(entry, kit, uses)
      kits = entry["kits"].is_a?(Hash) ? entry["kits"] : {}
      rules = kits[kit]
      core_tools = Array(entry["core_tools"])
      return ["ungradable", " (no rules logged for #{kit})"] unless rules.is_a?(Hash)
      return ["ungradable", " (tool calls not readable)"] if uses == :ungradable

      missing = uses.reject { |use| covers?(rules, core_tools, use) }
      return ["short of a tool", " (#{missing.map(&:name).uniq.join(", ")})"] unless missing.empty?

      narrower = kits.filter_map do |name, other|
        next if name == kit || !other.is_a?(Hash) || !narrower?(other, rules, core_tools)

        name if uses.all? { |use| covers?(other, core_tools, use) }
      end
      return ["wider than needed", " (#{narrower.sort.join(", ")} would also cover)"] unless narrower.empty?

      ["covers", ""]
    end

    # Whether a kit's rules declare +use+ (Toolkit::Resolved#declares?): a
    # tool-index group by the kit's groups; a built-in by its core list;
    # any other tool (a plugin's) unless the kit removes it.
    def covers?(rules, core_tools, use)
      return group_reached?(rules["groups"], use.group) if use.group && use.group != "chi"

      removed = Array(rules["removed"])
      return false if removed.include?(use.name)
      return true unless core_tools.include?(use.name)

      rules["all_core"] || Array(rules["core"]).include?(use.name) || Array(rules["added"]).include?(use.name)
    end

    def core_set(rules, core_tools)
      declared = rules["all_core"] ? core_tools : Array(rules["core"]) + Array(rules["added"])
      (declared & core_tools) - Array(rules["removed"])
    end

    # +other+ declares no more built-ins and reaches no more groups than
    # +rules+, and less of one of them.
    def narrower?(other, rules, core_tools)
      mine = core_set(rules, core_tools)
      theirs = core_set(other, core_tools)
      return false unless (theirs - mine).empty?

      groups_mine = rules["groups"]
      groups_theirs = other["groups"]
      groups_within = groups_mine == "all" || (groups_theirs != "all" && (Array(groups_theirs) - Array(groups_mine)).empty?)
      return false unless groups_within

      theirs.size < mine.size || (groups_mine == "all" && groups_theirs != "all") ||
        (groups_theirs != "all" && Array(groups_theirs).size < Array(groups_mine).size)
    end

    def group_reached?(groups, group)
      return true if ["all", :all].include?(groups)

      Array(groups).any? { |selector| Toolkit.group_matches?([selector], group) }
    end

    GRADES = ["covers", "short of a tool", "wider than needed", "ungradable"].freeze

    # Per graded kit: the grades, then what on mode would have done.
    def print_tallies(tallies)
      @stdout.puts("\nPer-kit")
      @stdout.puts("kit | suggestions | #{GRADES.join(" | ")} | would")
      tallies.sort.each do |kit, counts|
        would = counts.select { |key, _| key.start_with?("would:") }.sort
                      .map { |key, count| "#{key.delete_prefix("would:")} #{count}" }
        @stdout.puts("#{kit} | #{GRADES.sum { |grade| counts[grade] }} | " \
                     "#{GRADES.map { |grade| counts[grade] }.join(" | ")} | #{would.join(", ")}")
      end
    end

    def field(hash, key)
      return nil unless hash.is_a?(Hash)

      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
  end
end
