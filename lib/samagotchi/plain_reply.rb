# frozen_string_literal: true

module Samagotchi
  # A reply made plain for a surface that shows plain text only (ReplyFor
  # formatting "plain": a voice Shortcut reads it aloud). Deterministic: the
  # same text gives the same output. On the way out only, in chi web's wait
  # answers (SessionAccessRoutes#wait_result_json); the saved reply, the
  # reply file, the SSE stream and the web bubble keep the model's text.
  #
  # What goes: a heading's, a bullet's and a quote's lead, a table's pipes
  # (a separator row whole), a rule line, ** and __, backticks, a link's URL
  # (its text kept), emoji. What stays: a numbered list's numbers ("1. "),
  # which read well aloud, and a fenced code block's content, byte for byte
  # (its fence lines go; one never closed runs to the end).
  module PlainReply
    # A fence's opening line: its marker (``` or ~~~, three or more).
    FENCE_OPEN = /\A[ \t]*(`{3,}|~{3,})/
    HEADING = /^([ \t]*)\#{1,6}[ \t]+/
    BULLET = /^([ \t]*)[-*+][ \t]+/
    QUOTE = /^([ \t]*)(?:>[ \t]?)+/
    RULE = /^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*(\n|\z)/
    TABLE_SEPARATOR = /^[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*(\|[ \t]*:?-{3,}:?[ \t]*)*\|?[ \t]*(\n|\z)/
    TABLE_ROW = /^[ \t]*\|(.*?)\|?[ \t]*$/
    LINK = /\[([^\]\n]+)\]\([^)\s]+(?:[ \t]+"[^"]*")?\)/
    EMPHASIS = /\*\*|__/
    EMOJI = /[ \t]?[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE0F}\u{200D}]+/

    module_function

    # @param text [String, nil]
    # @return [String, nil] nil for nil
    def strip(text)
      return text if text.nil?

      lines = segments(text.gsub("\r\n", "\n")).flat_map do |code, body|
        next body if code || body.empty?

        plain(body.join("\n")).split("\n", -1).map { |line| line.rstrip.sub(/\A[ \t]+/, "") }
      end
      lines = lines.drop_while { |line| line.strip.empty? }
      lines.pop while lines.last&.strip&.empty?
      lines.join("\n")
    end

    # +text+'s lines as [code?, lines] runs: a fence's content (code) and
    # the text between fences, the fence lines left out.
    # @return [Array<Array(Boolean, Array<String>)>]
    def segments(text)
      runs = [[false, []]]
      close = nil
      text.split("\n", -1).each do |line|
        if close&.match?(line)
          close = nil
          runs << [false, []]
        elsif !close && (open = FENCE_OPEN.match(line))
          close = /\A[ \t]*#{Regexp.escape(open[1][0])}{#{open[1].size},}[ \t]*\z/
          runs << [true, []]
        else
          runs.last.last << line
        end
      end
      runs
    end

    # A text run made plain (no fence in it).
    def plain(text)
      out = text.gsub(TABLE_SEPARATOR, "").gsub(RULE, "")
      out = out.gsub(TABLE_ROW) { Regexp.last_match(1).split("|").map(&:strip).reject(&:empty?).join(", ") }
      out = out.gsub(HEADING, '\1').gsub(BULLET, '\1').gsub(QUOTE, '\1')
      out.gsub(LINK, '\1').gsub(EMPHASIS, "").delete("`").gsub(EMOJI, "")
    end
  end
end
