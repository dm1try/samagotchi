# frozen_string_literal: true

require "json"
require_relative "tool_response"
require_relative "tool_ids"
require_relative "llm_context_edit"
require_relative "llm_context_stale"

module Samagotchi
  # What the model is sent of the stored conversation: the one step
  # between a session's messages and the three places that format them
  # for a request (KernelLoop#format_prompt and #warmup_prompt, the native
  # prompt; ChatLoop#wire_messages, the chat messages). A strategy may
  # change what is sent; the session keeps the originals.
  #
  # Under +none+ (the default) nothing changes: #messages returns the
  # conversation it was given, the same Array of the same entries, so the
  # prompt is byte for byte what it was before the view existed.
  #
  # Under a strategy of layers (:stale, :forget), each applied edit saved
  # on a tool_response entry (LLMContextEdit) whose kind is one of the
  # layers sends that run's output as its stub. The entry stays where it
  # is, with its role and tool_call_id, so a call keeps its response and
  # the image plan (which indexes by entry) lines up. A stub keeps the
  # output's "[name]" lead (Gemma's prompt writes response:NAME from it),
  # and the run's images go with its text (images and image_counts kept
  # consistent). An entry the view can't split for sure (its runs don't
  # match its ids, or its images can't be told apart by run) is sent whole.
  # The view only counts the runs: whatever saves an edit on a run checks
  # the entry's runs against its batch's call names first
  # (ToolResponse.runs_named), and the entry's content never changes.
  #
  # With the forget layer on, every output with a stored id is sent with
  # it after its lead, "[read]\n[#t41] …" (plan D2: only then), so the
  # model can name it to forget_outputs; a legacy entry's derived ids are
  # never shown (they can't be forgotten), nor is the id of a run that
  # doesn't pair with its call for sure (LLMContextStale.paired_runs: a
  # "ran as:" line, an output holding a run separator), which
  # forget_outputs can't name either. A forget's stub carries its
  # note once: the outputs one forget_outputs call forgot that follow one
  # another (no other output between them) point to the first one's
  # instead, and a forget's kept lines (LLMContextEdit#keep) follow its
  # stub. A forgotten output that isn't a read says how to restore it
  # (re-reading the file is a read's restore).
  class LLMContextView
    NONE = :none
    LAYERS = LLMContextEdit::KINDS

    # @return [Array<Symbol>] the layers; empty under none
    attr_reader :layers

    # What +entries+ send, in chars: their contents (a parts list's text
    # parts) and their calls' names and arguments. The chat loop's context
    # estimate and the apply rule's payoff count so.
    def self.chars(entries)
      entries.sum do |entry|
        content = entry[:content]
        chars = if content.is_a?(Array)
                  content.sum { |part| part.is_a?(Hash) ? (part[:text] || part["text"]).to_s.length : 0 }
                else
                  content.to_s.length
                end
        chars + Array(entry[:tool_calls]).sum do |call|
          call.is_a?(Hash) ? call[:name].to_s.length + call[:arguments].to_json.length : 0
        end
      end
    end

    # @param strategy [Symbol, Array<Symbol>] :none, or the layers
    def initialize(strategy: NONE)
      @layers = strategy == NONE ? [] : Array(strategy).map(&:to_sym) & LAYERS
    end

    def none? = layers.empty?

    def strategy = none? ? NONE : layers

    # @param conversation [Array<Hash>] the stored entries, in order
    # @return [Array<Hash>] the entries to format
    def messages(conversation)
      return conversation if none?

      group = Group.new
      group.paired = forget? ? LLMContextStale.paired_runs(conversation).to_set { |run| run.ref.id } : Set.new
      conversation.each_with_index.map { |entry, index| edited(conversation, entry, index, group) }
    end

    def forget? = layers.include?(:forget)

    # The forget whose stub carries the note the next forgotten output of
    # the same call points to: its first id and its note, author and stamp.
    # +paired+: the ids of the runs that pair with their calls.
    Group = Struct.new(:first, :key, :paired)
    private_constant :Group

    READ = "read"

    private

    def edited(conversation, entry, index, group)
      return entry unless entry[:role].to_s == "tool_response"

      edits = LLMContextEdit.on(entry).select { |_id, edit| edit.applied? && layers.include?(edit.kind) }
      return entry if edits.empty? && !forget?

      refs = ToolIds.refs_at(conversation, index)
      stubbed = refs.each_index.select { |run| edits.key?(refs[run].id) }
      shown = forget? ? refs.each_index.select { |run| group.paired.include?(refs[run].id) && !refs[run].derived? } : []
      return whole(entry, group) if stubbed.empty? && shown.empty?

      texts = ToolResponse.runs(entry[:content], refs.size)
      return whole(entry, group) unless texts.size == refs.size

      images = stubbed.empty? ? :kept : kept_images(entry, refs.size, stubbed)
      return whole(entry, group) if images.nil?

      texts = texts.each_with_index.map do |text, run|
        edit = edits[refs[run].id] if stubbed.include?(run)
        text = edit ? stub(text, edit, refs[run], group) : whole(text, group)
        shown.include?(run) ? with_id(text, refs[run].id) : text
      end
      sent = entry.merge(content: texts.map(&:text).join(ToolResponse::SEPARATOR))
      images == :kept ? sent : with_images(sent, images)
    end

    # +sent+ as it is: an output between two forgotten ones ends their run.
    def whole(sent, group)
      group.key = nil
      sent
    end

    # The run's text with its id after its lead.
    def with_id(text, id)
      text.with(body: "[##{id}] #{text.body}")
    end

    def stub(text, edit, ref, group)
      lead = text.name ? "[#{text.name}] " : ""
      ToolResponse::RunText.new(name: text.name, lead: lead, body: stub_body(text, edit, ref, group))
    end

    # A stale stub's note; a forget's note (or, after the first of its
    # call's forgotten outputs in a row, a pointer to that one), its
    # restore hint (not for a derived id: it names nothing the model can
    # restore) and its kept lines.
    def stub_body(text, edit, ref, group)
      return whole(edit.stub, group) unless edit.kind == :forget

      key = [edit.note, edit.by, edit.staged_at]
      if group.key == key
        head = "(forgotten with #{group.first}: see its note)"
      else
        group.first = ref.id
        group.key = key
        head = edit.stub
      end
      head += " [restore: #{ref.id}]" unless text.name == READ || ref.derived?
      [head, *kept_lines(text.body, edit.keep, edit.keep_offset)].join("\n")
    end

    # The kept ranges of +body+'s lines, each under a "lines A-B kept:"
    # line, A and B as the model named them (+offset+ past the body's own:
    # a ranged read's file lines); a range is cut to the body, one wholly
    # outside it goes.
    def kept_lines(body, keep, offset)
      lines = body.lines
      keep.filter_map do |first, last|
        from = [first - offset, 1].max
        to = [last - offset, lines.size].min
        next if from > to

        "lines #{from + offset}-#{to + offset} kept:\n#{lines[(from - 1)..(to - 1)].join.chomp}"
      end
    end

    # The entry's [images, image_counts] without the stubbed runs' ones;
    # nil when they can't be told apart by run.
    def kept_images(entry, run_count, stubbed)
      images = Array(entry[:images])
      return [[], nil] if images.empty?
      return [[], nil] if run_count == 1

      counts = entry[:image_counts]
      return nil unless counts.is_a?(Array) && counts.size == run_count && counts.sum == images.size

      offset = 0
      kept = counts.each_with_index.flat_map do |count, run|
        slice = images[offset, count]
        offset += count
        stubbed.include?(run) ? [] : slice
      end
      [kept, counts.each_with_index.map { |count, run| stubbed.include?(run) ? 0 : count }]
    end

    def with_images(entry, (images, counts))
      return entry.except(:images, :image_counts) if images.empty?

      entry.merge(images: images, image_counts: counts)
    end
  end
end
