# frozen_string_literal: true

require "json"
require "time"
require_relative "../../lib/samagotchi"

module ModelNotesReport
  # One stored session's numbers (script/model_notes_report.rb): nothing of
  # its text, only the id, the model, the notes its prompt carried and
  # counts. How each is read from the session file:
  #
  # - steps: the model entries (role "model"), one per request, as the
  #   step limit counts them.
  # - calls: the tool calls in order: a chat entry's tool_calls, a native
  #   (Qwen or Gemma) entry's calls read from its text with chi's
  #   ToolCallParser.
  # - edits: calls named edit or write (attempts; a failed edit counts).
  # - commits: execute calls whose command runs `git [options] commit`
  #   (read with the guardrails' ShellLex: one of its simple commands is
  #   git, after any VAR=value words, then options, then commit).
  # - first_edit / first_commit: the 1-based place of the first such call
  #   among all calls (nil: none).
  # - longest_no_edit: the most calls in a row without an edit, before the
  #   first, between two or after the last.
  # - bare_amp: execute calls with a bare `&` (a background operator; not
  #   &&, 2>&1, >&, &> or one in quotes).
  # - continues: turns that ran without a prompt of their own, from the
  #   session's analytics.json (<dir>/<id>/analytics.json). A file written
  #   after 2026-10-09 has continue: on every turn record, true on a
  #   Continue's, and that mark is the count (a reminder's turn and a turn
  #   whose prompt !rollback erased aren't continues). An older file has no
  #   mark: its
  #   turn records whose id is no turn prompt's turn_id are counted instead
  #   (a step-limit Continue is such a turn, so is a due reminder's turn).
  #   A file whose prompts carry no turn_id (before 2026-10-02) counts
  #   records minus prompts. nil without analytics.json.
  # - steers: user lines that reached a running turn: input messages (kind
  #   "input": the user's, chi send's or a parent's; not a wake turn's
  #   turn_start one) and steers a person sent (kind "steer" from user or
  #   parent_agent: a Continue's text).
  # - nudges: the other steers (a plugin's, such as the loop guard).
  # - follow_ups: user prompts that started a turn after the first one
  #   (not a delegate report's wake).
  SessionStats = Data.define(:id, :model, :created_at, :notes, :steps, :calls, :edits, :commits, :first_edit,
                             :first_commit, :longest_no_edit, :bare_amp, :continues, :steers, :nudges, :follow_ups) do
    # Commits per 100 steps (nil without steps).
    def commits_per_100 = steps.positive? ? (commits * 100.0 / steps) : nil

    # The notes part of the group key: "name@digest" each, "+"-joined, in
    # the recorded order; "none" without notes (or in an older file).
    def notes_key = SessionStats.notes_key(notes)

    def self.notes_key(notes)
      return "none" if notes.empty?

      notes.map { |note| note.digest.to_s.empty? ? note.name : "#{note.name}@#{note.digest}" }.join("+")
    end

    def to_h
      super.merge(notes: notes.map { |note| note.to_h.compact }, notes_key: notes_key,
                  commits_per_100: commits_per_100&.round(2))
    end
  end

  # Reads a session file into SessionStats.
  module SessionReader
    EDIT_TOOLS = %w[edit write].freeze
    EXECUTE = "execute"
    PERSON_STEER_SOURCES = Samagotchi::Steer::PERSON_SOURCES
    DELEGATE_REPORT = Samagotchi::Steer::DELEGATE_REPORT
    LEX = Samagotchi::Guardrails::ShellLex
    # git's options that take the next word as their value.
    GIT_VALUE_OPTIONS = %w[-C -c --git-dir --work-tree --namespace --exec-path --config-env].freeze

    # One parsed tool call.
    Call = Data.define(:name, :args)

    module_function

    # @param path [String] a <session id>.json
    # @return [SessionStats]
    # @raise [JSON::ParserError, KeyError, TypeError, ArgumentError] not a session file
    def read(path)
      data = JSON.parse(File.read(path))
      raise TypeError, "not a session" unless data.is_a?(Hash)

      session = Samagotchi::Session.from_h(data)
      stats(session, records: turn_records(File.join(File.dirname(path), session.id.to_s, "analytics.json")))
    end

    # @param session [Samagotchi::Session]
    # @param records [Array<Hash>, nil] analytics.json's turn records
    def stats(session, records: nil)
      messages = session.messages.select { |message| message.is_a?(Hash) }
      calls = messages.select { |message| message[:role].to_s == "model" }.flat_map { |entry| calls_of(entry) }
      edits = calls.each_index.select { |index| edit?(calls[index]) }
      commits = calls.each_index.select { |index| commit?(calls[index]) }
      SessionStats.new(
        id: session.id.to_s, model: session.model_name.to_s, created_at: session.created_at.to_s,
        notes: session.prompt_notes, steps: messages.count { |message| message[:role].to_s == "model" },
        calls: calls.size, edits: edits.size, commits: commits.size,
        first_edit: edits.first&.succ, first_commit: commits.first&.succ,
        longest_no_edit: longest_gap(edits, calls.size), bare_amp: calls.count { |call| bare_amp?(call) },
        continues: continues(messages, records), **steering(messages)
      )
    end

    # The tool calls of a model entry.
    # @return [Array<Call>]
    def calls_of(entry)
      if entry[:tool_calls].is_a?(Array) && !entry[:tool_calls].empty?
        entry[:tool_calls].filter_map do |call|
          next unless call.is_a?(Hash)

          Call.new(name: (call[:name] || call["name"]).to_s, args: arguments(call[:arguments] || call["arguments"]))
        end
      else
        content = entry[:content].is_a?(String) ? entry[:content] : ""
        parser = native_parser(content)
        parser ? parser.read(content).map { |call| Call.new(name: call[:name].to_s, args: call[:args] || {}) } : []
      end
    end

    def arguments(value)
      return value if value.is_a?(Hash)

      parsed = JSON.parse(value.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def native_parser(content)
      if content.include?("<tool_call>")
        Samagotchi::ToolCallParser::Qwen.new(Samagotchi::ModelProfile.qwen36)
      elsif content.include?("<|tool_call>")
        Samagotchi::ToolCallParser::Gemma.new(Samagotchi::ModelProfile.gemma4)
      end
    end

    def edit?(call) = EDIT_TOOLS.include?(call.name)

    def command(call)
      return nil unless call.name == EXECUTE

      value = call.args["command"] || call.args[:command]
      value.is_a?(String) ? value : nil
    end

    def commit?(call)
      text = command(call)
      return false unless text

      LEX.simple_commands(LEX.lex(text)).any? { |words| words.is_a?(Array) && git_commit?(words) }
    end

    # `git [options] commit …`, after any VAR=value words.
    def git_commit?(words)
      words = words.drop_while { |word| word.match?(/\A[A-Za-z_]\w*=/) }
      return false unless File.basename(words.first.to_s) == "git"

      rest = words.drop(1)
      until rest.empty?
        word = rest.shift
        return word == "commit" unless word.start_with?("-")

        rest.shift if GIT_VALUE_OPTIONS.include?(word)
      end
      false
    end

    # An execute command with a `&` that sends something to the background:
    # the lexer's & operator, unless a word starting with > follows it (&>).
    def bare_amp?(call)
      text = command(call)
      return false unless text&.include?("&")

      tokens = LEX.lex(text)
      tokens.each_with_index.any? do |(kind, value), index|
        following = tokens[index + 1]
        kind == :op && value == "&" && !(following && following[0] == :word && following[1].start_with?(">"))
      end
    end

    # The most calls in a row with no edit among them.
    def longest_gap(edits, total)
      bounds = [-1, *edits, total]
      bounds.each_cons(2).map { |from, to| to - from - 1 }.max
    end

    def continues(messages, records)
      return nil unless records

      marked = records.count { |record| record["continue"] == true }
      return marked if records.any? { |record| record.key?("continue") }

      prompts = messages.select { |message| Samagotchi::Steer.turn_prompt?(message) }
      ids = prompts.map { |message| message[:turn_id] }
      return [records.size - prompts.size, 0].max if ids.any? { |id| id.to_s.empty? }

      known = ids.map(&:to_s)
      records.count { |record| !known.include?(record["id"].to_s) }
    end

    def steering(messages)
      users = messages.select { |message| message[:role].to_s == "user" }
      steers, others = users.select { |message| Samagotchi::Steer.steer?(message) }
                            .partition { |message| PERSON_STEER_SOURCES.include?(message[:source].to_s) }
      inputs = users.count { |message| Samagotchi::Steer.input?(message) && message[:turn_start] != true }
      prompts = users.count do |message|
        Samagotchi::Steer.turn_prompt?(message) && message[:source].to_s != DELEGATE_REPORT
      end
      { steers: inputs + steers.size, nudges: others.size, follow_ups: [prompts - 1, 0].max }
    end

    # analytics.json's turn records, nil without a readable file.
    def turn_records(path)
      return nil unless File.file?(path)

      records = JSON.parse(File.read(path))["turn_records"]
      records.is_a?(Array) ? records.select { |record| record.is_a?(Hash) } : nil
    rescue JSON::ParserError, TypeError, NoMethodError, SystemCallError
      nil
    end
  end
end
