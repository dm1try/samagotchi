# frozen_string_literal: true
module Samagotchi
  # OutputFormatter strips model wire-format tokens from raw engine output at
  # render time, so downstream renderers (web UI, terminal UI) never show the
  # model's internal control/literal vocabulary.
  #
  # Two token families survive KernelLoop#run's strip_thought_blocks():
  #   * Gemma control tokens: <|turn>, <|tool_call>...<tool_call|>,
  #     <|tool_response>...<tool_response|>, <|think|>, <|channel>thought...,
  #     <channel|>, <|tool>declaration...<tool|> blocks, <|"|> delimiter.
  #   * Qwen prompt-literal blocks: [[SAMAGOTCHI_LITERAL_*]]
  #     (<tool_call>, </think>,
  #     …) which strip_thought_blocks does NOT remove.
  #
  # IMPORTANT: control-token matching is ENUMERATED by name, never a broad
  # <[a-z_]{1,40}> wildcard. A wildcard eats arbitrary <word> content in
  # tool/file output (e.g. a tool result containing "<div>" or "<resp>" would be
  # silently mangled). If a new control token is added elsewhere, add its name to
  # CONTROL_NAMES (and any new bare-literal form) here before it can appear in
  # rendered output.
  module OutputFormatter
    # The complete vocabulary of known control-token names. Matched inside their
    # wrapper forms; bare <name> content (no pipe) is deliberately preserved.
    CONTROL_NAMES = %w[
      turn
      end_of_turn
      tool_call
      tool_response
      tool
      think
      channel
    ].freeze

    # Tokens are stripped individually by name (INDIVIDUAL_RE), which preserves the
    # tool-call / declaration *body* content while removing only the markers. The
    # body (e.g. `call:read{path:'x'}`) is real, readable output and must remain.

    # Individual control tokens matched inside their wrapper forms. Each
    # alternative requires at least one pipe (leading or trailing) so a bare
    # <word> in the surrounding content is NOT stripped:
    #   <|name> / <name|> / <|name|>
    INDIVIDUAL_RE = Regexp.new(
      '<\\|(?:' + CONTROL_NAMES.join('|') + ')\\|?>' \
      '|<(?:' + CONTROL_NAMES.join('|') + ')\\|>'
    )
    INDIVIDUAL_RE.freeze

    # Angle-bracketed literal tokens stripped wholesale (including the thought
    # channel's trailing word). Applied before INDIVIDUAL_RE so multi-part tokens
    # are removed as a unit.
    # Angle-bracketed literal tokens stripped wholesale (including the thought
    # channel's trailing word). Applied before INDIVIDUAL_RE so multi-part tokens
    # are removed as a unit. Pipes are escaped; angle brackets are literal.
    LITERALS_RE = /<\|"\|>|<\|\w*channel>thought|<end_of_turn>/.freeze

    # Qwen prompt-literal placeholders, e.g. </think>.
    PROMPT_LITERALS = /\[\[SAMAGOTCHI_LITERAL_[A-Z_]+\]\]/.freeze

    # Qwen3.6 thinking blocks: <think>...</think> (including empty)
    QWEN_THINK_RE = /<think>.*?<\/think>/m.freeze
    # Qwen tool_call XML blocks that survive when a tool call is rendered as text
    # e.g. <tool_call>\n<function=list_reminders>\n</function>\n</tool_call>
    QWEN_TOOL_CALL_RE = /<tool_call>.*?<\/tool_call>/m.freeze
    module_function

    # Remove both control-token and prompt-literal token families from +text+.
    # Known literals are stripped first (as whole units), then remaining tokens are
    # stripped by name inside their wrappers (bodies preserved). Whitespace runs
    # are collapsed and leading/trailing whitespace trimmed so removing a mid-sentence
    # tag leaves no stray double-space or blank line. Internal newlines are preserved
    # so a multi-line response stays readable. Blank / token-only input returns "".
    def strip(text)
      cleaned =
        remove_tokens(text)
        .gsub(/[ \t]+/, " ")
        .gsub(/ *\n */, "\n")
        .strip
      cleaned.empty? ? '' : cleaned
    end

    # The same tokens as #strip, but the text keeps its layout (indentation,
    # runs of spaces); only the blank lines removed blocks leave collapse.
    # For showing a whole saved answer (the attached TUI's join).
    def strip_markup(text)
      remove_tokens(text).gsub(/\n[ \t]*\n(?:[ \t]*\n)+/, "\n\n").strip
    end

    def remove_tokens(text)
      text.to_s
          .gsub(QWEN_THINK_RE, '')
          .gsub(QWEN_TOOL_CALL_RE, '')
          .gsub(LITERALS_RE, '')
          .gsub(INDIVIDUAL_RE, '')
          .gsub(PROMPT_LITERALS, '')
          # orphaned closing tags that may remain after block removal
          .gsub(/<\/?think>/, '')
          .gsub(/<\/?tool_call>/, '')
    end
  end
end
