# frozen_string_literal: true

require "json"
require "time"
require_relative "tool_response"
require_relative "tool_ids"
require_relative "llm_context_edit"
require_relative "model_profile"
require_relative "tool_call_parser"
require_relative "tools/builtin_calls"
require_relative "tools/tool_path"

module Samagotchi
  # The stale layer (LLMContextStrategy :stale): a file read that a later
  # read superseded is sent as a stub, "[read] lib/x.rb lines 1-200:
  # superseded by a later read". Deterministic: no model call, no note of
  # the model's. Superseded means a later read of the same file covering
  # the read's lines; a read that failed (its output an "Error") supersedes
  # nothing. An edit or write of the file doesn't (the user, 2026-10-07:
  # edit-driven stubs wait for P3's turn_end and payoff rules; #found's
  # +changes+ has them). Shell reads (cat, sed -n) don't count.
  #
  # Nothing per run says what a built-in call read, so the calls are worked
  # out from the model entries, in both formats: a chat entry's tool_calls,
  # paired with each result by tool_call_id; a native entry's call markup
  # (Qwen's <tool_call>, Gemma's <|tool_call>, whichever the entry holds: a
  # session may have switched models), paired in order with the runs of the
  # joined result after it. A result whose runs don't open with their calls'
  # "[name]" leads (ToolResponse.runs_named; a corrected call's "ran as:"
  # line) is left alone.
  #
  # An edit names its run by its ToolIds id (ToolIds.refs_at: stored, or
  # derived for a legacy entry) and is saved on the entry
  # (LLMContextEdit.store) applied at once: the request about to be sent is
  # the first with the stub (apply next_request; payoff and turn_end come
  # later). A run with any edit already keeps it.
  module LLMContextStale
    BY = "chi"
    READ = "read"
    CHANGES = %w[edit write].freeze
    WHOLE = (1..Float::INFINITY)

    # A file call's run: the entry it sits in (+index+) and its ToolIds
    # ref, the call's tool, the path as the model wrote it (+shown+) and
    # expanded, the lines a read asked for (WHOLE for all), whether its
    # output is an error, whether it holds only part of what was asked
    # (#partial?), and the output's length.
    FileRun = Data.define(:index, :ref, :name, :shown, :path, :lines, :failed, :partial, :size) do
      def read? = name == READ

      # +other+, an earlier read of the same file, is stale after this
      # run: a read covering its lines, or (+changes+) an edit or write.
      def supersedes?(other, changes: false)
        return false if failed || partial || path != other.path
        return changes unless read?

        lines.begin <= other.lines.begin && lines.end >= other.lines.end
      end
    end

    # A read to stub (#found).
    Found = Data.define(:run, :by, :note)

    module_function

    # Saves the stale edits +conversation+ doesn't have yet on its entries.
    # @return [Array<LLMContextEdit>] the edits saved
    def apply!(conversation, now: Time.now.utc.iso8601(3), root: Dir.pwd)
      edits(conversation, now: now, root: root).map do |index, edit|
        LLMContextEdit.store(conversation[index], edit)
        edit
      end
    end

    # The stale edits not yet on +conversation+'s entries, each with the
    # index of the entry it goes on. +root+: what a relative path is
    # relative to (the tools read from the process's directory).
    # @return [Array<Array(Integer, LLMContextEdit)>]
    def edits(conversation, now:, root: Dir.pwd)
      found(conversation, root: root).map do |stale|
        [stale.run.index, LLMContextEdit.new(id: stale.run.ref.id, kind: :stale, note: stale.note, by: BY, staged_at: now,
                                             applied_at: now)]
      end
    end

    # The reads to stub that have no edit yet: each read, the first later
    # run that superseded it (+by+; the replay benchmark applies the edit
    # at the request after it, as chi does) and the stub's note. A stub
    # that wouldn't be shorter than the output is left out. +changes+: an
    # edit or write of the file supersedes a read too. Off in chi (the
    # user, 2026-10-07: right after an edit the model is usually still
    # editing against the read); kept for P3, which may stub on edits at
    # turn end or under its payoff rule.
    # @return [Array<Found>]
    def found(conversation, root: Dir.pwd, changes: false)
      runs = file_runs(conversation, root)
      runs.each_with_index.filter_map do |run, at|
        next unless run.read?
        next if LLMContextEdit.on(conversation[run.index]).key?(run.ref.id)

        by = runs[(at + 1)..].find { |later| later.supersedes?(run, changes: changes) }
        next unless by

        note = note(run, by)
        Found.new(run: run, by: by, note: note) if run.size > "[#{run.name}] #{note}".length
      end
    end

    # What the stub says after the "[read]" lead.
    def note(run, by)
      lines = if run.lines == WHOLE
                ""
              else
                " lines #{run.lines.begin}-#{run.lines.end.infinite? ? "end" : run.lines.end}"
              end
      "#{run.shown}#{lines}: superseded by a later #{by.name}"
    end

    # The read, edit and write runs of +conversation+, in order.
    # @return [Array<FileRun>]
    def file_runs(conversation, root)
      batch = []
      conversation.each_with_index.with_object([]) do |(entry, index), runs|
        case entry[:role].to_s
        when "model" then batch = calls(entry)
        when "tool_response"
          runs.concat(results(conversation, index, batch).filter_map { |ref, call, text| file_run(index, ref, call, text, root) })
        end
      end
    end

    # A model entry's calls, each [tool_call_id (nil for a native one), the
    # call as dispatched (Tools::BuiltinCalls.build)].
    def calls(entry)
      if entry[:tool_calls].is_a?(Array) && !entry[:tool_calls].empty?
        return entry[:tool_calls].map do |call|
          [field(call, :id), Tools::BuiltinCalls.build(field(call, :name).to_s, arguments(field(call, :arguments)))]
        end
      end

      content = entry[:content].to_s
      parser = native_parser(content)
      return [] unless parser

      parser.read(parser.strip_thought(content)).map do |call|
        [nil, Tools::BuiltinCalls.build(call[:name], call[:args], raw: call[:raw])]
      end
    end

    # A tool_response entry's runs, each [its ref, its call, its text]; none
    # when they can't be paired for sure.
    def results(conversation, index, batch)
      entry = conversation[index]
      refs = ToolIds.refs_at(conversation, index)
      if entry[:tool_call_id]
        # Paired by an id its batch holds once: a provider may send an
        # empty or repeated id, and a wrong pairing names the wrong file.
        id = entry[:tool_call_id].to_s
        matches = id.empty? ? [] : batch.select { |call_id, _| call_id.to_s == id }
        call = matches.one? ? matches.first.last : nil
        texts = call && refs.size == 1 ? ToolResponse.runs_named(entry[:content], [call[:name]]) : nil
        return texts ? [[refs.first, call, texts.first.text]] : []
      end

      calls = batch.map(&:last)
      texts = ToolResponse.runs_named(entry[:content], calls.map { |call| call[:name] })
      return [] unless texts && texts.size == refs.size

      refs.zip(calls, texts.map(&:text))
    end

    def file_run(index, ref, call, text, root)
      name = call[:name].to_s
      return nil unless name == READ || CHANGES.include?(name)

      shown = (name == READ ? call[:content] : call[:path]).to_s.strip
      return nil if shown.empty?

      body = text.sub(ToolResponse::LEAD, "")
      FileRun.new(index: index, ref: ref, name: name, shown: shown,
                  path: File.expand_path(Tools::ToolPath.normalize(shown), root),
                  lines: name == READ ? lines(call) : WHOLE, failed: body.lstrip.start_with?("Error"),
                  partial: partial?(body), size: text.length)
    end

    # The read tool's head/tail preview of a big file (Tools::Read) or an
    # output ToolRunner cut at max_tool_output_chars: it doesn't hold all
    # the lines asked for, so it supersedes nothing.
    PREVIEW = "[TRUNCATED_PREVIEW_HEAD]"
    CUT = /\[cut: \d+ of \d+ chars; read it in parts\]\z/

    def partial?(body)
      body.start_with?("truncated=true") || body.include?(PREVIEW) || body.match?(CUT)
    end

    # The lines a read asked for: from start_line (1) to end_line (the end).
    def lines(call)
      first = line(call[:start_line]) || 1
      last = line(call[:end_line]) || Float::INFINITY
      first..last
    end

    def line(value)
      number = value.is_a?(Integer) ? value : Integer(value.to_s.strip, 10)
      number.positive? ? number : nil
    rescue ArgumentError, TypeError
      nil
    end

    def field(hash, key)
      return nil unless hash.is_a?(Hash)

      hash.key?(key) ? hash[key] : hash[key.to_s]
    end

    def arguments(value)
      return value if value.is_a?(Hash)

      parsed = JSON.parse(value.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    QWEN_CALL = "<tool_call>"
    GEMMA_CALL = "<|tool_call>"

    def native_parser(content)
      if content.include?(GEMMA_CALL)
        @gemma ||= ToolCallParser::Gemma.new(ModelProfile.gemma4)
      elsif content.include?(QWEN_CALL)
        @qwen ||= ToolCallParser::Qwen.new(ModelProfile.qwen36)
      end
    end

    private_class_method :file_runs, :calls, :results, :file_run, :partial?, :lines, :line, :field, :arguments, :native_parser
  end
end
