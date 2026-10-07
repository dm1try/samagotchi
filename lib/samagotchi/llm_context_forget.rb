# frozen_string_literal: true

require "time"
require_relative "tool_response"
require_relative "tool_ids"
require_relative "token_usage"
require_relative "llm_context_edit"
require_relative "llm_context_stale"
require_relative "llm_context_apply"
require_relative "llm_context_view"
require_relative "tools/forget_outputs"

module Samagotchi
  # The forget layer (LLMContextStrategy :forget, experimental): the
  # model's forget_outputs call on the running turn's conversation. A
  # forget saves an LLMContextEdit of kind :forget on each output's entry
  # (LLMContextEdit.store), staged (no applied_at); the apply rule
  # (LLMContextApply, run at once by +apply+) then sends the batch at the
  # next request or holds it for the turn's end, and the result says which.
  # A restore takes a forget off (staged or applied); it goes out with the
  # next request.
  #
  # Only the model's own tool outputs, named by their stored ids
  # (ToolIds): never the system prompt, a user message, a steer or a
  # context note (they have no id), never a legacy entry's derived id, and
  # the call stays with its result (only the result's text is stubbed). Per
  # id, refused with a reason:
  # - an output from the last +protect_steps+ steps (the model may still
  #   be working with it);
  # - a read of a file an edit or write touched in those steps
  #   (LLMContextStale.protected_ids), unless the forget keeps some of its
  #   lines (keep): wiping what the model edits against makes it redo the
  #   read (CLM's lesson);
  # - a keep that holds all of the output, an output too small for a stub
  #   to free anything (SMALL), an output already stubbed or forgotten, an
  #   id nothing in context has.
  # A read is never restored: reading the file again is its restore, and
  # the file may have changed.
  module LLMContextForget
    BY = "model"
    READ = "read"
    # An output this short (its text after the lead, in chars) frees
    # nothing as a stub ("(forgotten with t41: see its note) [restore: t42]").
    SMALL = 80

    # The turn a forget_outputs call runs in: its conversation (the
    # entries the edits are saved on) and its ContextStatus (nil: none).
    Turn = Data.define(:conversation, :context)

    # One output a call may name: its entry, its ToolIds ref, its tool,
    # its text (without the "[name]" lead) and its step; +offset+: what
    # turns a line of its text into the line a keep names (a read's file
    # lines: start_line - 1), +preview+: a read that came back as a big
    # file's head/tail preview (no file lines to keep).
    Output = Data.define(:index, :ref, :name, :body, :step, :offset, :preview) do
      def read? = name == READ

      # The lines a keep may name: [first, last].
      def lines = [offset + 1, offset + body.lines.size]
    end

    module_function

    # Runs a forget_outputs +call+ on +turn+, under the turn's
    # +llm_context+ (LLMContextStrategy::Resolved: its layers and
    # protect_steps). The conversation's last step is the one holding the
    # call (both loops add the model's entry before its calls run).
    # @param apply [#call] → LLMContextApply::Outcome: the apply rule at a
    #   request, on the turn's conversation (KernelLoop#apply_llm_context!)
    # @return [String] the tool result
    def call(turn, call, llm_context:, apply:, root: Dir.pwd, now: Time.now.utc.iso8601(3))
      request = Tools::ForgetOutputs.parse(call)
      conversation = turn.conversation
      return restore(turn, request.restore, llm_context) if request.restore? && request.ids.empty?
      return "Error: forget_outputs needs ids to forget (or restore: ids to bring back)" if request.ids.empty?
      if request.note.empty?
        return "Error: forget_outputs needs a note: what you learned from these outputs (facts, file:line, " \
               "what's ruled out, NEXT), since it is all that stays of them"
      end

      forgotten, refused = forget(conversation, request, llm_context.protect_steps, root, now)
      lines = if forgotten.empty?
                ["nothing forgotten"]
              else
                [applied_line(conversation, forgotten, apply.call, llm_context.active_layers)]
              end
      lines << restore(turn, request.restore, llm_context) if request.restore?
      lines.concat(refused_lines(refused))
      lines.join("\n")
    end

    # Saves a staged forget on each output +request+ names that may go.
    # @return [Array(Array<String>, Hash{String => String})] the ids
    #   forgotten, and the refused ones with why
    def forget(conversation, request, protect_steps, root, now)
      outputs = outputs(conversation)
      last = LLMContextStale.step_count(conversation)
      # The steps before the call's own: protected_ids counts that one too.
      kept_reads = LLMContextStale.protected_ids(conversation, steps: protect_steps.positive? ? protect_steps + 1 : 0,
                                                               root: root)
      refused = {}
      forgotten = request.ids.select do |id|
        why = refusal(conversation, outputs[id], request.keep[id], last, protect_steps, kept_reads)
        refused[id] = why if why
        why.nil?
      end
      forgotten.each do |id|
        output = outputs[id]
        keep = request.keep.fetch(id, [])
        edit = LLMContextEdit.new(id: id, kind: :forget, note: request.note, by: BY, staged_at: now, applied_at: nil,
                                  keep: keep, keep_offset: keep.empty? ? 0 : output.offset)
        LLMContextEdit.store(conversation[output.index], edit)
      end
      [forgotten, refused]
    end

    # Why +output+ can't go (a String for the result), nil when it can.
    # +last+: the call's own step; the protect_steps steps before it are
    # the model's latest outputs.
    def refusal(conversation, output, keep, last, protect_steps, kept_reads)
      return "no output with that id in context (ids look like t42)" unless output
      return "already forgotten or stubbed" if LLMContextEdit.on(conversation[output.index]).key?(output.ref.id)
      if protect_steps.positive? && output.step >= last - protect_steps
        return "from your last #{protect_steps} step#{"s" unless protect_steps == 1}; you may still need it, forget it later"
      end
      return keep_refusal(output, keep) if keep

      if kept_reads.include?(output.ref.id)
        first, = output.lines
        return "a read of a file you edited in your last #{protect_steps} steps; keep the lines you edit against " \
               "(keep: [\"#{output.ref.id}:#{first}-#{first + 20}\"]) or forget it later"
      end
      return "too small: its stub would free nothing" if output.body.length <= SMALL

      nil
    end

    # Why +keep+ can't be kept of +output+, nil when it can: a preview has
    # no file lines, a range must fall in the output's lines, and some of
    # it must go.
    def keep_refusal(output, keep)
      return "a preview of a big file: keep needs its lines; read a range of it instead" if output.preview

      first, last = output.lines
      outside = keep.reject { |from, to| from <= last && to >= first }
      unless outside.empty?
        shown = outside.map { |from, to| "#{from}-#{to}" }.join(", ")
        return "keep #{shown} is outside its lines (#{first}-#{last}#{", the file's" if output.read?})"
      end
      kept = keep.flat_map { |from, to| ([from, first].max..[to, last].min).to_a }.uniq.size
      return "keep holds all of it; nothing to forget" if kept >= last - first + 1

      nil
    end

    # Takes the forgets of +ids+ off: any that hasn't reached the prompt
    # yet, and one that has unless it is a read's (reading the file again
    # is its restore). The next request sends them whole, whatever the
    # apply rule (the model wants the text now), so the context estimate
    # starts over (ContextStatus#edited!).
    # @return [String] the result's line(s)
    def restore(turn, ids, llm_context)
      conversation = turn.conversation
      outputs = outputs(conversation)
      restored = []
      refused = {}
      sent = false
      ids.each do |id|
        output = outputs[id]
        edit = output && LLMContextEdit.on(conversation[output.index])[id]
        if edit.nil? || edit.kind != :forget
          refused[id] = "not forgotten"
        elsif output.read? && edit.applied?
          refused[id] = "a read: read the file again instead (it may have changed)"
        else
          LLMContextEdit.remove(conversation[output.index], id)
          restored << output
          sent ||= edit.applied?
        end
      end
      lines = restored.empty? ? [] : [restored_line(turn, restored, sent, llm_context)]
      (lines + refused_lines(refused)).join("\n")
    end

    def restored_line(turn, restored, sent, llm_context)
      ids = restored.map { |output| output.ref.id }.join(", ")
      return "restored #{ids}: its stub was never sent" unless sent

      turn.context&.edited!
      view = LLMContextView.new(strategy: llm_context.active_layers)
      tail = LLMContextView.chars(view.messages(turn.conversation)[restored.map(&:index).min..])
      "restored #{ids}: the next request sends it whole again, now whatever llm_context.apply says (the server " \
        "reads the #{k(tail)} from it on again)"
    end

    # Every output in +conversation+ a stored id names and that pairs with
    # its call for sure (LLMContextStale.paired_runs), by id.
    # @return [Hash{String => Output}]
    def outputs(conversation)
      LLMContextStale.paired_runs(conversation).each_with_object({}) do |run, found|
        next if run.ref.derived?

        name = run.call[:name].to_s
        body = run.text.sub(ToolResponse::LEAD, "")
        found[run.ref.id] = Output.new(index: run.index, ref: run.ref, name: name, body: body, step: run.step,
                                       offset: name == READ ? read_offset(run.call) : 0,
                                       preview: name == READ && LLMContextStale.partial?(body))
      end
    end

    # A read's first line, less one (start_line; 1 without one).
    def read_offset(call)
      first = Integer(call[:start_line].to_s.strip, 10)
      first.positive? ? first - 1 : 0
    rescue ArgumentError, TypeError
      0
    end

    # What the apply rule did with the batch the forgotten ids are in.
    def applied_line(conversation, forgotten, outcome, layers)
      ids = forgotten.join(", ")
      applied = outcome.applied.map(&:id)
      if forgotten.all? { |id| applied.include?(id) }
        return "forgot #{ids}: applied, the next request sends the stubs (#{frees(outcome.freed_chars)}; the " \
               "server reads the #{k(outcome.tail_chars)} after them again)"
      end

      freed, = LLMContextApply.weigh(conversation, layers: layers, edits: staged(conversation))
      "forgot #{ids}: staged until the turn ends (the staged stubs: #{frees(freed)} then)"
    end

    # The edits saved unapplied, as [entry index, edit] pairs.
    def staged(conversation)
      conversation.each_with_index.flat_map do |entry, index|
        next [] unless entry[:role].to_s == "tool_response"

        LLMContextEdit.on(entry).values.reject(&:applied?).map { |edit| [index, edit] }
      end
    end

    def refused_lines(refused)
      return [] if refused.empty?

      ["not done:"] + refused.map { |id, why| "- #{id}: #{why}" }
    end

    def frees(chars) = chars.positive? ? "frees #{k(chars)}" : "frees nothing, the stubs are as long"

    # "12.4k tokens", chars/4.
    def k(chars)
      tokens = (chars / TokenUsage::CHARS_PER_TOKEN).ceil
      tokens >= 1000 ? format("%.1fk tokens", tokens / 1000.0) : "#{tokens} tokens"
    end

    private_class_method :forget, :refusal, :keep_refusal, :restored_line, :read_offset, :applied_line, :staged,
                         :refused_lines, :frees, :k
  end
end
