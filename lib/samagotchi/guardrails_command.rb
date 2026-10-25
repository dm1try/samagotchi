# frozen_string_literal: true

require "json"

require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "config"
require_relative "bridge/card_store"
require_relative "guardrails/approvals"
require_relative "guardrails/parent_policy"
require_relative "host_registry"
require_relative "session"
require_relative "system_one"

module Samagotchi
  # `chi guardrails`: the guardrails' own maintenance commands, on this
  # machine only (docs/guardrails.md, "System 1"). `replay` is the record
  # seed: System 1 judges every approval this machine's sessions already
  # answered, and the judgment and the user's answer go to the log as they
  # would live. A rule's record then starts with the asks the user really
  # decided on, instead of waiting for a few days of live ones.
  class GuardrailsCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi guardrails <subcommand> [options]
        replay [--dry-run] [--threshold T] [--model M]
          Judge every approval this machine's sessions have already answered
          (their cards, $XDG_STATE_HOME/samagotchi/sessions/<id>/cards.json)
          through System 1 and write the judgment and the user's answer to
          guardrails/judgments.jsonl, so a rule's record starts with the asks
          the user really decided on. Asks with no approval card, unanswered
          ones, and question ids a previous replay already logged are skipped.
          A parent agent's answer is not the user's: only its deny is logged,
          and only when the parent could have allowed (the session's
          guardrails.parent_answers allows "permit" and the ask is not
          user-only). --threshold overrides guardrails.system_one.threshold
          for the table; --model overrides the configured model for this run.
          --dry-run judges and prints the table without writing a line. Needs
          guardrails.system_one.mode audit or on and a guardrails.system_one.host
          (exit 2 without one).
    TEXT

    SUBCOMMANDS = %w[replay].freeze
    FLAGS = {
      "replay" => CLI::Flags.new(help: HELP_WORDS, args: false) do |f|
        f.switch "--dry-run"
        f.value "--threshold"
        f.value "--model"
      end
    }.freeze
    # The labels that mean the user let the call through.
    ALLOW_LABELS = %w[allow_once allow_wide].freeze
    # replay's table, in column order: the rule, how many asks it had, how
    # many the user allowed, how many they denied, how many System 1 would
    # have auto-allowed at the threshold, the false allows among them (the
    # model said allow, the user did not), and the asks with no judgment.
    COLUMNS = %w[rule asks allowed denied auto false_allows no_judgment].freeze
    # Why an ask in a cards file was not replayed, in the words the summary
    # uses.
    SKIP_WORDS = {
      already_replayed: "already replayed",
      answered_by_parent: "answered by a parent agent",
      parent_cannot_allow: "answered by a parent that could not allow",
      unanswered: "unanswered",
      no_approval: "no approval card",
      no_question_id: "no question id"
    }.freeze

    # One ask a replay judges: the card's question id, the session it came
    # from, its approval as the card saved it, the label its answer gives,
    # and when the user was asked.
    Ask = Data.define(:question_id, :session_id, :approval, :label, :asked_at)

    # @param argv [Array<String>] the arguments after "guardrails"
    # @param client [SystemOne::Client, nil] the judgment client; nil: the
    #   one config.yml describes (the seam the specs pass a fake through)
    # @param sessions_dir [String, nil] where the sessions are; nil: this
    #   machine's ($XDG_STATE_HOME/samagotchi/sessions)
    # @param log [SystemOne::Log, nil] the judgments log; nil: the one beside
    #   the approvals store
    def initialize(argv, stdout: $stdout, stderr: $stderr, client: nil, sessions_dir: nil, log: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @client = client
      @sessions_dir = sessions_dir
      @log = log
    end

    # @return [Integer] exit status: 0 done, 2 a usage error or no System 1
    #   client to judge with
    def run
      @sub = @argv[0]
      if @sub.nil? || HELP_WORDS.include?(@sub)
        @stdout.puts(USAGE)
        return CLI::Exit::OK
      end
      return usage_error("unknown subcommand #{@sub}") unless SUBCOMMANDS.include?(@sub)

      parsed = parse_flags(FLAGS.fetch(@sub), @argv[1..])
      return parsed if parsed.is_a?(Integer)

      replay(parsed.options)
    end

    private

    def command_name = @sub ? "chi guardrails #{@sub}" : "chi guardrails"

    def replay(options)
      threshold = threshold(options[:threshold])
      return usage_error(threshold) if threshold.is_a?(String)

      client = @client || SystemOne::Client.from_config(host_registry: HostRegistry.new, model: options[:model])
      if client.nil?
        error_line("chi guardrails replay: no System 1 client — set guardrails.system_one.mode to audit or on " \
                   "and guardrails.system_one.host in config.yml")
        return CLI::Exit::USAGE
      end

      sessions_dir = @sessions_dir || Session.default_state_dir
      log = @log || SystemOne::Log.new(dir: Guardrails::Approvals.dir_for(sessions_dir))
      replayed = File.exist?(log.path) ? log.entries.filter_map { |entry| entry["question_id"] if entry["origin"] == "replay" }.to_set : Set.new
      @dry_run = options[:dry_run] ? true : false

      asks = []
      skipped = Hash.new(0)
      malformed = 0
      if Dir.exist?(sessions_dir)
        Dir.children(sessions_dir).sort.each do |name|
          path = File.join(sessions_dir, name, Bridge::CardStore::FILE)
          next unless File.file?(path)

          entries = sidecar(path)
          if entries.nil?
            malformed += 1
            next
          end

          entries.each do |entry|
            ask = ask_of(entry, name, replayed, sessions_dir)
            next if ask.nil?

            ask.is_a?(Symbol) ? skipped[ask] += 1 : asks << ask
          end
        end
      end

      stats = asks.map { |ask| judge(ask, client, log, threshold, sessions_dir) }
      print_table(stats, threshold, client, skipped, malformed)
      CLI::Exit::OK
    end

    # The asks of one session's cards file, or nil when it isn't one: a
    # sidecar that doesn't parse costs one warning line, never the run.
    def sidecar(path)
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path), symbolize_names: true)
      return nil unless data.is_a?(Hash) && data[:entries].is_a?(Array)

      data[:entries]
    rescue StandardError => e
      error_line("chi guardrails replay: #{path}: unreadable cards (#{e.class}: #{e.message}); skipped")
      nil
    end

    # One card entry as an ask to judge: an Ask, a skip reason (:already_replayed,
    # :answered_by_parent, :parent_cannot_allow, :unanswered, :no_approval,
    # :no_question_id), or nil for an entry that is not a question at all.
    def ask_of(entry, session_id, replayed, sessions_dir)
      return nil unless entry.is_a?(Hash) && entry[:type] == "question"

      pending = entry[:pending_question]
      return :no_approval unless pending.is_a?(Hash) && pending[:approval].is_a?(Hash)

      question_id = pending[:id].to_s
      return :no_question_id if question_id.empty?
      return :already_replayed if replayed.include?(question_id)

      answer = entry[:answer]
      label = if entry[:cancelled]
                "none"
              elsif answer.nil?
                return :unanswered
              elsif answer[:by] == "parent_agent"
                # A parent's allow is not the user's decision. Its deny is a
                # label only where the parent could have allowed: a parent
                # that was not allowed to permit says nothing about the user
                # (docs/guardrails.md, "System 1").
                return :answered_by_parent unless label_for(answer, pending[:approval][:scopes]) == "deny"
                return :parent_cannot_allow unless parent_may_permit?(pending, session_id, sessions_dir)

                "deny"
              else
                label_for(answer, pending[:approval][:scopes])
              end

      Ask.new(question_id: question_id, session_id: session_id, approval: pending[:approval],
              label: label, asked_at: pending[:created_at])
    end

    # Whether this session's parent could have allowed the ask: not a
    # user-only ask, and a parent level that permits one. No session file:
    # not permitted.
    def parent_may_permit?(pending, session_id, sessions_dir)
      return false if pending[:user_only] == true

      session = session_of(session_id, sessions_dir)
      return false if session.nil?

      Guardrails::ParentPolicy.for_session(session).allow?("permit")
    end

    # The session a card belongs to, or nil when there is no session file;
    # read once per session for the run.
    def session_of(session_id, sessions_dir)
      return nil unless Session.valid_id?(session_id)
      return nil unless File.exist?(Session.session_file(session_id, state_dir: sessions_dir))

      (@sessions ||= {})[session_id] ||= begin
        Session.load(session_id, state_dir: sessions_dir)
      rescue StandardError
        nil
      end
    end

    # What the user did, as the log's label: the scope they took, a denial
    # when the answer is not one of the offered scopes, none for an ask that
    # was cancelled (docs/guardrails.md, "System 1").
    def label_for(answer, scopes)
      index = answer[:selected_indices]&.first
      return "deny" if index.nil?

      scopes = Array(scopes)
      if index < scopes.size
        scopes[index] == "once" ? "allow_once" : "allow_wide"
      else
        "deny"
      end
    end

    # Judge one ask, write its two lines unless this is a dry run, and return
    # what the table counts. A judgment that never came is written with p
    # null, exactly as the live audit writes it.
    def judge(ask, client, log, threshold, sessions_dir)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      answers = begin
        client.ask(state: SystemOne::ApprovalQuestion.state(ask.approval, session_title: session_title(ask, sessions_dir)),
                   questions: { SystemOne::ApprovalQuestion::ID => SystemOne::ApprovalQuestion.question })
      rescue StandardError => e
        Samagotchi::Log.warn(:guardrails, "system_one_replay_ask_failed", error: "#{e.class}: #{e.message}")
        nil
      end
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      p = answers && answers[SystemOne::ApprovalQuestion::ID]&.noul

      unless @dry_run
        id = log.judgment(session_id: ask.session_id, rule: ask.approval[:rule], source: ask.approval[:source],
                          tool: ask.approval[:tool], **SystemOne::ApprovalQuestion.call_fields(ask.approval),
                          repo_name: ask.approval[:repo_name], p: p, threshold: threshold, model: client.model,
                          latency_ms: latency_ms, decision: "replay", origin: "replay",
                          question_id: ask.question_id, asked_at: ask.asked_at)
        log.label(id, ask.label)
      end

      { rule: ask.approval[:rule].to_s, label: ask.label, p: p, session: ask.session_id }
    end

    # The session's title, as the ask's state carries it; nil when there is
    # no session file (the cards alone are enough to replay).
    def session_title(ask, sessions_dir)
      session_of(ask.session_id, sessions_dir)&.display_title
    end

    # The threshold for this run: --threshold, or guardrails.system_one.threshold.
    # @return [Float, String] the number, or the usage error's message
    def threshold(value)
      return Config.get("guardrails.system_one.threshold").to_f if value.nil?

      number = Float(value.to_s.strip)
      return "--threshold takes a number between 0 and 1, got #{value}" if number.negative? || number > 1.0

      number
    rescue ArgumentError, TypeError
      "--threshold takes a number between 0 and 1, got #{value}"
    end

    def print_table(stats, threshold, client, skipped, malformed)
      rows = stats.group_by { |row| row[:rule] }.map { |rule, asks| rule_row(rule, asks, threshold) }
      rows.sort_by! { |rule, count, _| [-count, rule] }
      totals = ["total", *COLUMNS[1..].each_with_index.map { |_column, offset| rows.sum { |row| row[offset + 1] } }]
      all = rows + [totals]
      widths = COLUMNS.each_with_index.map { |column, index| [column.size, all.map { |row| row[index].to_s.size }.max].max }

      @stdout.puts(row_line(COLUMNS, widths))
      @stdout.puts(widths.map { |width| "-" * width }.join("  "))
      rows.each { |row| @stdout.puts(row_line(row, widths)) }
      @stdout.puts(row_line(totals, widths))

      sessions = stats.map { |row| row[:session] }.uniq.size
      @stdout.puts("#{stats.size} asks replayed from #{sessions} session#{"s" unless sessions == 1} " \
                   "· threshold #{threshold} · model #{client.model || "the host's default"}")
      notes = skipped.map { |reason, count| "#{count} #{SKIP_WORDS[reason] || reason}" }
      notes << "#{malformed} unreadable cards file#{"s" unless malformed == 1}" if malformed.positive?
      @stdout.puts("skipped: #{notes.sort.join(", ")}") unless notes.empty?
      @stdout.puts("dry run: nothing was written") if @dry_run
    end

    # One table row, columns left-aligned to their width.
    def row_line(values, widths)
      values.each_with_index.map { |value, index| value.to_s.ljust(widths[index]) }.join("  ").rstrip
    end

    # One rule's row: asks, allowed, denied, auto-allowed at the threshold,
    # false allows, asks with no judgment.
    def rule_row(rule, rows, threshold)
      allowed = rows.count { |row| ALLOW_LABELS.include?(row[:label]) }
      denied = rows.count { |row| row[:label] == "deny" }
      high = rows.select { |row| row[:p] && row[:p] >= threshold }
      [rule, rows.size, allowed, denied,
       high.count { |row| ALLOW_LABELS.include?(row[:label]) },
       high.count { |row| row[:label] == "deny" },
       rows.count { |row| row[:p].nil? }]
    end
  end
end
