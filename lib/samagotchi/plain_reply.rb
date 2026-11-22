# frozen_string_literal: true

module Samagotchi
  # A reply made plain for a surface that shows plain text only (ReplyFor
  # formatting "plain": a voice Shortcut reads it aloud). Deterministic: the
  # same text gives the same output. On the way out only, in chi web's wait
  # answers (SessionAccessRoutes#wait_result_json); the saved reply, the
  # reply file, the SSE stream and the web bubble keep the model's text.
  #
  # What goes: a heading's, a bullet's and a quote's lead, a table's pipes
  # (a separator row whole), a rule line, ** and __, backticks (a fence's
  # lines dropped, its content kept), a link's URL (its text kept), emoji.
  # What stays: a numbered list's numbers ("1. "), which read well aloud.
  module PlainReply
    FENCE = /^[ \t]*(```|~~~).*(\n|\z)/
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

      out = text.gsub("\r\n", "\n")
      out = out.gsub(FENCE, "").gsub(TABLE_SEPARATOR, "").gsub(RULE, "")
      out = out.gsub(TABLE_ROW) { Regexp.last_match(1).split("|").map(&:strip).reject(&:empty?).join(", ") }
      out = out.gsub(HEADING, '\1').gsub(BULLET, '\1').gsub(QUOTE, '\1')
      out = out.gsub(LINK, '\1').gsub(EMPHASIS, "").delete("`").gsub(EMOJI, "")
      out.lines.map { |line| line.rstrip.sub(/\A[ \t]+/, "") }.join("\n").strip
    end
  end
end
