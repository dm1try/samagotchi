# frozen_string_literal: true

require "digest"
require "time"
require_relative "block_fix/stamp"
require_relative "block_renderers"
require_relative "inline_widgets"
require_relative "markdown_parser"
require_relative "plugin/side_question"

module Samagotchi
  # A fenced block the page couldn't draw in the newest answer, asked for
  # again once (docs/internals/block-renderers.md, A failed block is asked
  # for again): where the block is in an answer's markdown, the side request
  # that asks for it again, and the checks on what came back. Pure Ruby: the
  # Engine's BlockFixPart runs the request and writes the conversation.
  module BlockFix
    # The side line's kind (SideUsage) and the asking source.
    SOURCE = "block-fix"
    # The Bridge feature (Bridge::FEATURES) a page checks before it asks.
    FEATURE = "block_fix"
    # IdleClient may retry a refused thinking setting: up to three requests.
    TIMEOUT_SECONDS = 25
    MAX_TOKENS = 6000
    MAX_SOURCE_BYTES = 16 * 1024
    # How much of the drawer's error goes into the request (model-influenced
    # text, in the user part only).
    MAX_REASON_CHARS = 300
    # Asks in flight per Engine at once.
    MAX_RUNNING = 2

    # The route's refusals (one message per condition), by reason code.
    REFUSALS = {
      block_too_large: "the block is over #{MAX_SOURCE_BYTES / 1024} KB",
      block_not_found: "that block isn't in the turn's answer",
      fix_busy: "#{MAX_RUNNING} fixes are being asked for already",
      fix_unavailable: "this session can't ask for a fix"
    }.freeze

    SYSTEM = "The last answer in the conversation below holds a fenced block a program could not draw. Answer " \
             "with the corrected block only, in one fence of the same language, and nothing else. Keep what it " \
             "shows and every id, label, option and text it has, unless the error requires a change."

    # Where a block is in an answer's text: the body's lines (0-based, both
    # ends inclusive; +last+ is first - 1 for an empty body) and the indent
    # its lines have there (a list item's).
    Place = Data.define(:first, :last, :indent)

    # What #extract read from the model's answer: the fixed source, or why
    # it is refused.
    Extracted = Data.define(:source, :refusal) do
      def ok? = refusal.nil?
    end

    module_function

    # The block's identity: the first 32 hex characters of SHA-256 over the
    # language and the normalised source.
    def key(lang, source)
      Digest::SHA256.hexdigest("#{lang}\0#{normalize(source)}")[0, 32]
    end

    # +source+ with \r\n and \r as \n and one trailing newline removed.
    def normalize(source)
      source.to_s.gsub(/\r\n?/, "\n").delete_suffix("\n")
    end

    # Whether #locate can parse (commonmarker is installed).
    def available? = MarkdownParser.available?

    # The first code block of +text+ in +lang+ whose source is +source+, as
    # commonmarker (the page's render's parser) reads it; nil when there is
    # none, or it sits in a blockquote (its lines carry "> ").
    # @return [Place, nil]
    def locate(text, lang:, source:) = locate_all(text, lang: lang, source: source).first

    # Every such block of +text+, in order (an answer may repeat one: a fix
    # patches every copy, so none is asked for again).
    # @return [Array<Place>]
    def locate_all(text, lang:, source:)
      return [] unless available?

      text = text.to_s
      want = normalize(source)
      lines = text.lines
      places = []
      each_code_block(text) do |node|
        next unless language_of(node.fence_info) == lang.to_s && normalize(node.string_content) == want
        next if in_blockquote?(node)

        place = place_of(node, lines)
        places << place if place
      end
      places
    end

    # +text+ with every block at +places+ holding +fixed+ (#replace from
    # the last, so the earlier places' lines stay where they were).
    def replace_all(text, places, fixed)
      places.sort_by(&:first).reverse.reduce(text.to_s) { |out, place| replace(out, place, fixed) }
    end

    # +text+ with the block at +place+ holding +fixed+: the fence lines kept,
    # each new line given the old body's indent, the text's own line ends.
    def replace(text, place, fixed)
      lines = text.to_s.lines
      eol = text.to_s.include?("\r\n") ? "\r\n" : "\n"
      body = normalize(fixed).split("\n", -1).map { |line| line.empty? ? eol : "#{place.indent}#{line}#{eol}" }
      before = lines[0...place.first]
      # A body at the very end without a line end (an unclosed fence) keeps none.
      after = lines[(place.last + 1)..] || []
      body[-1] = body[-1].delete_suffix(eol) if after.empty? && !lines.last.to_s.end_with?("\n") && body.any?
      (before + body + after).join
    end

    # What Engine#ask_side_model takes: the conversation up to and including
    # the answer as a transcript, then the failed block and its error.
    # @param messages [Array<Hash>] the conversation, display-only keys gone
    # @return [Array<Hash>]
    def request(messages:, lang:, source:, reason:)
      system = lang.to_s == InlineWidgets::LANG ? "#{SYSTEM}\n\n#{InlineWidgets::FIX_RULES}" : SYSTEM
      Plugin::SideQuestion.request(messages: messages, prompt: prompt(lang, source, reason), system: system)
    end

    # The question: the language, the error and the block.
    def prompt(lang, source, reason)
      body = normalize(source)
      fence = "`" * [3, (body.scan(/`+/).map(&:length).max || 0) + 1].max
      error = reason.to_s.strip[0, MAX_REASON_CHARS]
      "The #{lang} block below, from your last answer, could not be drawn.\nError: #{error}\n\n" \
        "#{fence}#{lang}\n#{body}\n#{fence}\n\nAnswer with the corrected block only, in one #{lang} fence."
    end

    # The fixed source in the model's +text+: the first fenced block, else
    # the whole answer when it has no fence.
    # @param cut_off [Boolean] the answer stopped at its token limit
    # @param failed [String] the source that failed
    # @return [Extracted]
    def extract(text, cut_off:, failed:)
      return Extracted.new(source: nil, refusal: "the fix was cut off") if cut_off

      source = normalize(first_fence(text.to_s) || text.to_s.strip)
      return Extracted.new(source: nil, refusal: "the fix was empty") if source.strip.empty?
      return Extracted.new(source: nil, refusal: "the fix was the same block") if source == normalize(failed)
      if source.bytesize > MAX_SOURCE_BYTES
        return Extracted.new(source: nil, refusal: "the fix is over #{MAX_SOURCE_BYTES / 1024} KB")
      end

      Extracted.new(source: source, refusal: nil)
    end

    # nil when +source+ may be tried, else the reason: a chi-ui block must
    # parse; any other language passes (only the page can draw it).
    def check(lang:, source:)
      return nil unless lang.to_s == InlineWidgets::LANG

      InlineWidgets.parse(source).error
    end

    def each_code_block(text, &)
      return unless text.include?("```") || text.include?("~~~")

      nodes = []
      Commonmarker.parse(text, options: { extension: { header_ids: nil } }).walk do |node|
        nodes << node if node.type == :code_block
      end
      nodes.each(&)
    end

    def language_of(info)
      word = info.to_s.split.first.to_s.downcase
      word if word.match?(BlockRenderers::LANG)
    end

    def in_blockquote?(node)
      parent = node.parent
      while parent
        return true if parent.type == :block_quote

        parent = parent.parent
      end
      false
    end

    # The body's line range and indent from the node's source position; nil
    # for an indented code block (no fence line).
    def place_of(node, lines)
      pos = node.source_position
      start = pos[:start_line] - 1
      fence_line = lines[start].to_s
      column = pos[:start_column] - 1
      fence = fence_line[column..].to_s[/\A(`{3,}|~{3,})/]
      return nil unless fence

      prefix = fence_line[0, column]
      indent = prefix.match?(/\A[ \t]*\z/) ? prefix : " " * prefix.length
      last = pos[:end_line] - 1
      last -= 1 if last > start && closing?(lines[last].to_s, fence)
      Place.new(first: start + 1, last: last, indent: indent)
    end

    def closing?(line, fence)
      mark = line.strip[/\A(`{3,}|~{3,})\z/]
      !mark.nil? && mark[0] == fence[0] && mark.length >= fence.length
    end

    def first_fence(text)
      return nil unless available?

      lines = text.lines
      each_code_block(text) do |node|
        return node.string_content if place_of(node, lines)
      end
      nil
    end
  end
end
