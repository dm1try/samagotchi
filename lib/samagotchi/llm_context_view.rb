# frozen_string_literal: true

require_relative "tool_response"
require_relative "tool_ids"
require_relative "llm_context_edit"

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
  class LLMContextView
    NONE = :none
    LAYERS = LLMContextEdit::KINDS

    # @return [Array<Symbol>] the layers; empty under none
    attr_reader :layers

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

      conversation.each_with_index.map { |entry, index| edited(conversation, entry, index) }
    end

    private

    def edited(conversation, entry, index)
      return entry unless entry[:role].to_s == "tool_response"

      edits = LLMContextEdit.on(entry).select { |_id, edit| edit.applied? && layers.include?(edit.kind) }
      return entry if edits.empty?

      refs = ToolIds.refs_at(conversation, index)
      stubbed = refs.each_index.select { |run| edits.key?(refs[run].id) }
      return entry if stubbed.empty?

      texts = ToolResponse.runs(entry[:content], refs.size)
      return entry unless texts.size == refs.size

      images = kept_images(entry, refs.size, stubbed)
      return entry if images.nil?

      stubbed.each { |run| texts[run] = stub(texts[run], edits[refs[run].id]) }
      with_images(entry.merge(content: texts.map(&:text).join(ToolResponse::SEPARATOR)), images)
    end

    def stub(text, edit)
      lead = text.name ? "[#{text.name}] " : ""
      ToolResponse::RunText.new(name: text.name, lead: lead, body: edit.stub)
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
