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
require_relative "toolkit_suggest"

module Samagotchi
  # `chi toolkit report`: compare the toolkit an audit suggestion named with
  # the tools the corresponding user turn actually called.
  class ToolkitReportCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi toolkit report [--days N]
        Grade audit suggestions against the tools each session turn called,
        including the target of call_tool. Shows covers, short-of-tool and
        wider-than-needed results, then a per-kit tally. Includes archived
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
        uses = tool_uses_by_turn(session.messages).fetch(entry["turn_number"].to_i, [])
        grade, detail = grade(entry, uses)
        kit = entry["kit"] || entry["default_kit"] || "(unknown)"
        tallies[kit][grade] += 1
        confidence = entry["confidence"].nil? ? "n/a" : format("%.2f", entry["confidence"])
        @stdout.puts("#{timestamp(entry["at"]).iso8601} #{id[0, 8]} turn #{entry["turn_number"]}: " \
                     "#{entry["raw"] || "no judgment"} (p=#{confidence}) → #{kit}: #{grade}#{detail}")
        @stdout.puts("  tools: #{uses.map(&:label).uniq.join(", ")}") unless uses.empty?
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

    # Tool calls grouped by the user's own prompt number; steers and merged
    # input lines remain part of that turn rather than starting another.
    def tool_uses_by_turn(messages)
      number = 0
      current = nil
      uses = Hash.new { |hash, key| hash[key] = [] }
      Array(messages).each do |message|
        if field(message, :role).to_s == "user"
          if ToolkitSuggest.owner_prompt?(message)
            number += 1
            current = number
          elsif Steer.participant_author?(field(message, :author))
            current = nil
          end
          next
        end
        next unless current

        calls = field(message, :tool_calls)
        Array(calls).each { |call| uses[current] << tool_use(call) }
      end
      uses.transform_values { |turn_uses| turn_uses.compact }
    end

    def tool_use(call)
      return unless call.is_a?(Hash)

      function = field(call, :function)
      name = (field(call, :name) || field(function, :name)).to_s
      arguments = field(call, :arguments) || field(function, :arguments) || field(call, :args)
      arguments = JSON.parse(arguments) if arguments.is_a?(String) && !arguments.empty?
      target = arguments.is_a?(Hash) ? (field(arguments, :tool) || field(arguments, :name)) : nil
      return ToolUse.new(name: name, group: nil, label: name) unless name == "call_tool" && target

      parts = target.to_s.split("/", 2)
      group, tool = parts.size == 2 ? parts : [nil, parts.first]
      ToolUse.new(name: tool, group: group, label: "call_tool→#{target}")
    rescue JSON::ParserError
      ToolUse.new(name: name, group: nil, label: name)
    end

    def grade(entry, uses)
      selected = entry["suggested"] || entry["default"]
      declared = Array(selected.is_a?(Hash) ? selected["tools"] : [])
      groups = selected.is_a?(Hash) ? selected["groups"] : []
      missing = uses.reject do |use|
        declared.include?(use.name) ||
          (use.group && use.group != "chi" && group_reached?(groups, use.group))
      end
      return ["short of a tool", " (#{missing.map(&:name).uniq.join(", ")})"] unless missing.empty?

      used = uses.map(&:name).uniq
      unused = declared - used
      return ["wider than needed", " (#{unused.size} unused declared)"] unless unused.empty?

      ["covers", ""]
    end

    def group_reached?(groups, group)
      return true if ["all", :all].include?(groups)

      Array(groups).any? { |selector| Toolkit.group_matches?([selector], group) }
    end

    def print_tallies(tallies)
      @stdout.puts("\nPer-kit")
      @stdout.puts("kit | suggestions | covers | short of a tool | wider than needed")
      tallies.sort.each do |kit, counts|
        @stdout.puts("#{kit} | #{counts.values.sum} | #{counts["covers"]} | " \
                     "#{counts["short of a tool"]} | #{counts["wider than needed"]}")
      end
    end

    def field(hash, key)
      return nil unless hash.is_a?(Hash)

      hash.key?(key) ? hash[key] : hash[key.to_s]
    end
  end
end
