# frozen_string_literal: true

require "json"
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
  # the read's lines, or (#found's +changes+) a successful edit or write of
  # the file: "superseded by a later edit". A run that failed (its output
  # an "Error") or holds only part of what it asked for supersedes nothing.
  # Edit-driven stubs are opt-in (llm_context.stale_edits); when one may be
  # sent is LLMContextApply's rule (the user, 2026-10-07: never mid-edit),
  # and no read of a file the last steps edited is stubbed
  # (#protected_ids). Shell reads (cat, sed -n) don't count.
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
  # A stub names its run by its ToolIds id (ToolIds.refs_at: stored, or
  # derived for a legacy entry); LLMContextApply saves it on the entry
  # (LLMContextEdit.store) when its rule lets it through. A run with any
  # edit already keeps it.
  module LLMContextStale
    BY = "chi"
    READ = "read"
    CHANGES = %w[edit write].freeze
    WHOLE = (1..Float::INFINITY)

    # A file call's run: the entry it sits in (+index+) and its ToolIds
    # ref, the call's tool, the path as the model wrote it (+shown+) and
    # expanded, the lines a read asked for (WHOLE for all), whether its
    # output is an error, whether it holds only part of what was asked
    # (#partial?), the output's length, and its step (1 for the
    # conversation's first model entry with calls, one more per such
    # entry).
    FileRun = Data.define(:index, :ref, :name, :shown, :path, :lines, :failed, :partial, :size, :step) do
      def read? = name == READ

      # +other+, an earlier read of the same file, is stale after this
      # run: a read covering its lines, or (+changes+) an edit or write.
      def supersedes?(other, changes: false)
        return false if failed || partial || path != other.path
        return changes unless read?

        lines.begin <= other.lines.begin && lines.end >= other.lines.end
      end
    end

    # A read to stub (#found). #change? when only an edit or write
    # superseded it (+changes+), no later read.
    Found = Data.define(:run, :by, :note) do
      def change? = !by.read?
    end

    module_function

    # The reads to stub that have no edit yet: each read, the first later
    # run that superseded it (+by+; the replay benchmark applies the edit
    # at the request after it, as chi does) and the stub's note. A stub
    # that wouldn't be shorter than the output is left out. +changes+: a
    # successful edit or write of the file supersedes a read too, when no
    # later read does (a later read is +by+ whenever there is one, so
    # Found#change? holds only for a read nothing but a change superseded).
    # Whether such a stub may be sent yet is LLMContextApply's call (the
    # user, 2026-10-07: right after an edit the model is usually still
    # editing against the read): at turn end, or when it pays off, and
    # never the read #protected_ids names.
    # @return [Array<Found>]
    def found(conversation, root: Dir.pwd, changes: false)
      runs = file_runs(conversation, root)
      runs.each_with_index.filter_map do |run, at|
        next unless run.read?
        next if LLMContextEdit.on(conversation[run.index]).key?(run.ref.id)

        later = runs[(at + 1)..]
        by = later.find { |other| other.read? && other.supersedes?(run) } ||
             (changes && later.find { |other| other.supersedes?(run, changes: true) })
        next unless by

        note = note(run, by)
        Found.new(run: run, by: by, note: note) if run.size > "[#{run.name}] #{note}".length
      end
    end

    # The ids of the reads stale never stubs: every read of each file an
    # edit or write (successful or not: a failed one is retried) touched in
    # the conversation's last +steps+ steps (protect_steps; 0: none). The
    # model is likely still editing against them, and any of them may hold
    # the lines it edits (an earlier range, or the only whole copy when a
    # later read came back cut). Steps count across the conversation.
    # @return [Set<String>]
    def protected_ids(conversation, steps:, root: Dir.pwd)
      return Set.new unless steps.positive?

      runs = file_runs(conversation, root)
      last = step_count(conversation)
      edited = runs.select { |run| !run.read? && run.step > last - steps }.to_set(&:path)
      runs.select { |run| run.read? && edited.include?(run.path) }.to_set { |run| run.ref.id }
    end

    # The conversation's steps: its model entries with calls.
    def step_count(conversation)
      conversation.count { |entry| entry[:role].to_s == "model" && !calls(entry).empty? }
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
      step = 0
      conversation.each_with_index.with_object([]) do |(entry, index), runs|
        case entry[:role].to_s
        when "model"
          batch = calls(entry)
          step += 1 unless batch.empty?
        when "tool_response"
          runs.concat(results(conversation, index, batch).filter_map do |ref, call, text|
            file_run(index, ref, call, text, root, step)
          end)
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

    def file_run(index, ref, call, text, root, step)
      name = call[:name].to_s
      return nil unless name == READ || CHANGES.include?(name)

      shown = (name == READ ? call[:content] : call[:path]).to_s.strip
      return nil if shown.empty?

      body = text.sub(ToolResponse::LEAD, "")
      FileRun.new(index: index, ref: ref, name: name, shown: shown,
                  path: File.expand_path(Tools::ToolPath.normalize(shown), root),
                  lines: name == READ ? lines(call) : WHOLE, failed: body.lstrip.start_with?("Error"),
                  partial: partial?(body), size: text.length, step: step)
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
