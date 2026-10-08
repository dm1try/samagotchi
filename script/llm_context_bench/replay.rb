# frozen_string_literal: true

require "json"
require_relative "../../lib/samagotchi"
require_relative "text_refs"

module LLMContextBench
  # A model's tool call: which request made it (the model entry's place
  # among the requests), its name and arguments, and what it targets.
  Call = Data.define(:request, :name, :args, :target)

  # One tool run's output, as chi stores it: the entry it sits in, its run
  # there and its id (Samagotchi::ToolIds.refs_at: the stored tool_ids, or
  # "e<index>.<run>" derived for an entry saved before them), the call that
  # made it, its text and size, and the identifiers it was the first to
  # bring into the conversation (the spike's "new identifiers").
  Output = Data.define(:id, :ordinal, :entry_index, :entry_ordinal, :run, :turn, :request, :name, :args, :target,
                       :tokens, :text, :new_idents) do
    def read? = name == "read"
  end

  # A session's file reads (Replay#read_counts): the reads of a path, those
  # of a path the session had read before (re_reads), and of those the ones
  # made after an earlier read of the path was stubbed (after_stub), split
  # by the stub's kind. A stub counts from the request that caused it: a
  # forget from the forget_outputs call that named the output, a stale one
  # from the next read of the path (the read that superseded it). Only
  # edits the session applied count (the model was sent those).
  ReadCounts = Data.define(:reads, :re_reads, :after_stub, :after_forget, :after_stale)

  # The LLM context edits a session applied (Replay#stubs): per kind, the
  # outputs stubbed and their tokens, and the forget_outputs calls.
  Stubs = Data.define(:stale, :stale_tokens, :forget, :forget_tokens, :forget_calls)

  # A stored session, read the way chi reads it (Samagotchi::Session.from_h),
  # laid out for replay: its requests (each model entry is one; request r's
  # prompt is every entry before it), its turns (a user input up to the
  # next), the calls each request made and every tool output, one per run
  # (a native batch's joined entry has a run per call, split as the
  # LLMContextView splits it).
  #
  # Native sessions keep their calls inside the model text (Qwen's
  # <tool_call> XML, Gemma's <|tool_call>): they are read with chi's own
  # ToolCallParser and paired with the batch's runs in order. Chat sessions
  # pair a result with its call by tool_call_id.
  class Replay
    TURN_KINDS = [nil, "input"].freeze

    attr_reader :session_id, :model, :messages, :requests, :turns, :calls, :outputs, :projects, :working_directory

    # @param path [String] a <session id>.json file
    def self.load(path)
      data = JSON.parse(File.read(path))
      session = Samagotchi::Session.from_h(data)
      new(session_id: session.id, model: session.model_name, messages: session.messages,
          working_directory: session.working_directory)
    end

    # The session files in +dir+ (<uuid>.json), heaviest first by what a
    # request resends (+top+ keeps that many), each with at least
    # +min_turns+ turns.
    # @return [Array<Replay>]
    def self.from_dir(dir, top: nil, min_turns: 2, only: nil)
      paths = Dir.glob(File.join(dir, "*.json"))
      paths = paths.select { |path| only.any? { |prefix| File.basename(path).start_with?(prefix) } } if only
      replays = paths.filter_map { |path| load_session(path) }.select { |replay| replay.turns.size >= min_turns }
      replays.sort_by! { |replay| [-replay.resent_tokens, replay.session_id] }
      top ? replays.first(top) : replays
    end

    # A session file's replay, nil for a JSON file that isn't one.
    def self.load_session(path)
      load(path)
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError
      nil
    end

    def initialize(session_id:, model:, messages:, working_directory: nil)
      @session_id = session_id.to_s
      @model = model.to_s
      @messages = messages
      @working_directory = working_directory&.to_s
      @projects = working_directory && File.dirname(working_directory.to_s)
      @requests = messages.each_index.select { |index| role(index) == "model" }
      @request_at = @requests.each_with_index.to_h
      @turns = turn_ranges
      paired = @requests.each_with_index.map { |index, request| model_calls(messages[index], request) }
      @calls = paired.map { |pairs| pairs.map(&:last) }
      @outputs = read_outputs(paired.flatten(1).to_h.except(nil))
    end

    # The model as a short name: without a host prefix ("openrouter:").
    def model_name = model.sub(%r{\A[\w.-]+:(?=[^\s:]*/)}, "")

    def short_id = session_id[0, 8]

    def role(index) = messages[index][:role].to_s

    # The turn +index+ falls in, -1 before the first.
    def turn_of(index)
      @turns.rindex { |range| range.begin <= index } || -1
    end

    # The request whose prompt first holds entry +index+ (nil: none does).
    def request_after(index)
      @requests.index { |entry| entry > index }
    end

    # The request a model entry is.
    def request_of(index) = @request_at[index]

    # Request +request+'s prompt: the entries before its model entry.
    def prompt_end(request) = @requests[request]

    # A model entry's text as resent, its native call markup and inline
    # thinking taken out (Replay#parts).
    # @return [Array(String, String, Array<Hash>)] prose, inline thinking,
    #   native calls ({name:, args:})
    def parts(entry)
      content = entry[:content].is_a?(String) ? entry[:content] : ""
      parser = native_parser(content)
      return [content, "", []] unless parser

      thinking = content.scan(%r{<think>(.*?)</think>}m).flatten.join("\n")
      [parser.strip_tool_calls(parser.strip_thought(content)), thinking, parser.read(content)]
    end

    # What a request resends of an entry, in tokens: its content and its
    # calls' arguments (never the stored thinking, which chi doesn't resend).
    def entry_tokens(entry)
      tokens = TextRefs.tokens(entry[:content])
      Array(entry[:tool_calls]).sum(tokens) { |call| TextRefs.tokens(call[:arguments]) }
    end

    # The session's reads, re-reads and re-reads after a stub (ReadCounts).
    def read_counts
      @read_counts ||= begin
        reads = outputs.select { |output| output.read? && !output.target.keys.empty? }
        by_path = Hash.new { |hash, key| hash[key] = [] }
        counts = Hash.new(0)
        reads.each do |output|
          earlier = by_path[output.target.keys.first]
          unless earlier.empty?
            counts[:re_reads] += 1
            kinds = earlier.filter_map { |prev| stub_kind_before(prev, output.request, reads) }.uniq
            counts[:after_stub] += 1 unless kinds.empty?
            kinds.each { |kind| counts[:"after_#{kind}"] += 1 }
          end
          earlier << output
        end
        ReadCounts.new(reads: reads.size, re_reads: counts[:re_reads], after_stub: counts[:after_stub],
                       after_forget: counts[:after_forget], after_stale: counts[:after_stale])
      end
    end

    # The applied LLM context edits (Stubs).
    def stubs
      @stubs ||= begin
        edited = outputs.filter_map { |output| (edit = applied_edit(output)) && [edit.kind, output.tokens] }
        tally = ->(kind) { edited.select { |found, _| found == kind } }
        Stubs.new(stale: tally.call(:stale).size, stale_tokens: tally.call(:stale).sum(0.0) { _2 }.round,
                  forget: tally.call(:forget).size, forget_tokens: tally.call(:forget).sum(0.0) { _2 }.round,
                  forget_calls: calls.flatten.count { |call| call.name == FORGET })
      end
    end

    # What the whole conversation resends, in tokens.
    def resent_tokens
      @resent_tokens ||= messages.sum { |entry| entry_tokens(entry) }
    end

    private

    FORGET = Samagotchi::Tools::ForgetOutputs::NAME

    # The applied edit saved on +output+'s entry for its id, nil for none.
    def applied_edit(output)
      edit = Samagotchi::LLMContextEdit.on(messages[output.entry_index])[output.id]
      edit if edit&.applied?
    end

    # +prev+'s stub kind when that stub came before request +request+, else
    # nil.
    def stub_kind_before(prev, request, reads)
      edit = applied_edit(prev)
      return nil unless edit && request

      cause = if edit.kind == :forget
                forget_requests[prev.id]
              else
                reads.find { |other| other.ordinal > prev.ordinal && other.target.keys.first == prev.target.keys.first }&.request
              end
      edit.kind if cause && cause < request
    end

    # The request of the first forget_outputs call that named each id.
    def forget_requests
      @forget_requests ||= calls.flatten.select { |call| call.name == FORGET }.each_with_object({}) do |call, found|
        request = Samagotchi::Tools::ForgetOutputs.parse(call.args.transform_keys(&:to_sym))
        request.ids.each { |id| found[id] ||= call.request }
      end
    end

    def turn_ranges
      starts = messages.each_index.select { |index| role(index) == "user" && TURN_KINDS.include?(messages[index][:kind]) }
      starts.each_with_index.map { |start, k| start...(starts[k + 1] || messages.size) }
    end

    # The calls a model entry made, each with its tool_call_id (nil for a
    # native one).
    # @return [Array<Array(String, Call)>]
    def model_calls(entry, request)
      raw = if entry[:tool_calls].is_a?(Array) && !entry[:tool_calls].empty?
              entry[:tool_calls].map { |call| { id: call[:id], name: call[:name].to_s, args: arguments(call[:arguments]) } }
            else
              parts(entry).last.map { |call| { id: nil, name: call[:name].to_s, args: call[:args] || {} } }
            end
      raw.map do |call|
        [call[:id], Call.new(request: request, name: call[:name], args: call[:args],
                             target: TextRefs.target(call[:name], call[:args], projects: projects))]
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
      if content.include?("<tool_call>") || content.include?("<think>")
        @qwen ||= Samagotchi::ToolCallParser::Qwen.new(Samagotchi::ModelProfile.qwen36)
      elsif content.include?("<|tool_call>")
        @gemma ||= Samagotchi::ToolCallParser::Gemma.new(Samagotchi::ModelProfile.gemma4)
      end
    end

    # @param by_id [Hash{String => Call}] the chat calls by tool_call_id
    def read_outputs(by_id)
      seen = Set.new
      outputs = []
      last_request = nil
      entry_ordinal = 0
      messages.each_with_index do |entry, index|
        last_request = request_of(index) if role(index) == "model"
        unless role(index) == "tool_response"
          seen.merge(TextRefs.idents(text_of(entry), projects: projects))
          next
        end

        batch = last_request ? @calls[last_request] : []
        runs(entry, index).each do |ref, text|
          call = entry[:tool_call_id] ? by_id[entry[:tool_call_id]] : batch[ref.run]
          outputs << output(entry, index, ref, text, call, last_request, outputs.size, entry_ordinal, seen)
        end
        entry_ordinal += 1
      end
      outputs
    end

    def output(_entry, index, ref, text, call, request, ordinal, entry_ordinal, seen)
      name = call&.name || ref_name(text) || "?"
      args = call&.args || {}
      target = call&.target || TextRefs.target(name, args, projects: projects)
      idents = TextRefs.idents(text, projects: projects)
      fresh = idents - seen - JSON.generate(args).split
      seen.merge(idents)
      Output.new(id: ref.id, ordinal: ordinal, entry_index: index, entry_ordinal: entry_ordinal, run: ref.run,
                 turn: turn_of(index), request: request, name: name, args: args, target: target,
                 tokens: TextRefs.tokens(text), text: text, new_idents: fresh)
    end

    # An entry's runs, each with its id, as the LLMContextView splits them;
    # one run (the first id) when they don't line up.
    def runs(entry, index)
      refs = Samagotchi::ToolIds.refs_at(messages, index)
      content = entry[:content].to_s
      texts = Samagotchi::ToolResponse.runs(content, refs.size).map(&:text)
      return [[refs.first, content]] unless texts.size == refs.size

      refs.zip(texts)
    end

    def ref_name(text) = Samagotchi::ToolResponse::LEAD.match(text)&.[](1)

    def text_of(entry)
      content = entry[:content]
      content.is_a?(String) ? content : content.to_s
    end
  end
end
