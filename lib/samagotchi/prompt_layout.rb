# frozen_string_literal: true

require_relative "prompt_part"

module Samagotchi
  # Where each SystemPrompt::Item of a build sits in the prompt the build
  # made, worked out once beside it (SystemPrompt#prompt_parts_for): the
  # place fields of its PromptPart (at, len, lead, digest, head). The
  # sections are joined by "\n" (the stable ones, then the volatile ones),
  # each section's items by its join; joins and the scope headings that
  # belong to no item fall outside every span (a note's heading is the
  # first note's lead). See docs/internals/working-set.md (Prompt parts as
  # sent).
  #
  # The tool declarations: on a chat host they are not in the prompt (no
  # place); native, inside the base text ("You have access to the following
  # tools:"), whose own slice leaves them out, or, on Gemma, after the last
  # section, where the prompt was rstripped before them: an item running
  # into that strip is cut at it.
  class PromptLayout
    # What the base text says before the declarations: SystemPrompt#assist_system_prompt
    # writes it from here, so the two can't drift.
    TOOLS_LEAD = "You have access to the following tools:\n\n"

    # @param prompt [String] the built prompt
    # @param sections [Array<SystemPrompt::Section>] in prompt order
    # @param declarations [String, nil] the native declarations text (nil: chat)
    # @param tail [Boolean] Gemma's: the declarations follow the rstripped prompt
    def initialize(prompt, sections, declarations:, tail:)
      @head = PromptPart.digest_of(prompt, 16)
      @spans = {}.compare_by_identity
      @end = tail && declarations ? prompt.length - declarations.length : prompt.length
      at = 0
      sections.each do |section|
        offset = at
        section.items.each do |item|
          @spans[item] = [offset, item.sent.length.clamp(0, [@end - offset, 0].max)]
          offset += item.sent.length + section.join.length
        end
        at += section.text.length + 1
      end
      @tools = tools_span(sections, declarations, tail)
    end

    # Whether the declarations sit inside the base text (their chars move
    # out of the base part, SystemPrompt#prompt_parts_for).
    def tools_in_base? = !@tools.nil? && !@tools_tail

    # The place fields of +item+'s part.
    # @return [Hash]
    def place(item)
      at, len = @spans.fetch(item)
      body = item.text
      if item.kind == :base && tools_in_base?
        from = @tools[0] - at - item.lead.length
        body = body[0, from].to_s + body[(from + @tools[1])..].to_s
      end
      { at: at, len: len, lead: item.lead.length, digest: PromptPart.digest_of(body), head: @head }
    end

    # The tools part's place fields: none on a chat host.
    # @return [Hash]
    def tools_place
      return {} unless @tools

      { at: @tools[0], len: @tools[1], lead: 0, head: @head }
    end

    private

    # [at, len] of the declarations in the prompt, nil when they aren't in
    # it (chat) or can't be found.
    def tools_span(sections, declarations, tail)
      return nil unless declarations

      if tail
        @tools_tail = true
        return [@end, declarations.length]
      end

      base = sections.first&.items&.first
      return nil unless base&.kind == :base

      index = base.text.index("#{TOOLS_LEAD}#{declarations}")
      index && [@spans.fetch(base)[0] + base.lead.length + index + TOOLS_LEAD.length, declarations.length]
    end
  end
end
