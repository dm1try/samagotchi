# frozen_string_literal: true

require_relative "guardrails/shell_lex"

module Samagotchi
  # An execute command as the steps a person reads, for the web's tool row
  # (display only: the guardrails read the command themselves). Built from
  # ShellLex's tokens and their spans, so each step's text is a slice of the
  # command as the model wrote it. Rules, in order:
  #
  # - a heredoc's body leaves its step's text and becomes its +heredoc+
  #   ({tag:, lines:}), also one inside a "$(cat <<'EOF' … EOF)" argument;
  # - steps are split at && || ; | |& & and newlines; a ( … ) subshell stays
  #   one step; +op+ is the operator before a step (nil for the first);
  # - a leading "cd X &&" / "cd X;" becomes +cd+ (only the first);
  # - a pipeline's last "| head …" / "| tail …" becomes the +limit+ of the
  #   step before it ("head 20", "tail", "head -c 60");
  # - a lone echo of a marker-wrapped string ("=== x ===", "--- x ---",
  #   "## x") becomes the +label+ of the next step; a bare marker echo
  #   ("---", "====", "") only spaces the output and goes;
  # - anything the parser isn't sure of (a quote or heredoc left open,
  #   for/while/until/if/case/function bodies, { … } groups, unbalanced
  #   parentheses) gives nil: the UI then shows the title and the raw
  #   command.
  module CommandSteps
    Step = Data.define(:text, :op, :label, :limit, :heredoc) do
      def initialize(text:, op: nil, label: nil, limit: nil, heredoc: nil) = super

      def to_h = super.compact
    end

    Parsed = Data.define(:cd, :steps) do
      def to_h = { cd: cd, steps: steps.map(&:to_h) }.compact
    end

    Lex = Guardrails::ShellLex

    SPLIT = ["&&", "||", ";", "|", "|&", "&", "\n"].freeze
    KEYWORDS = %w[for while until if then elif else fi case esac select do done function { }].freeze
    LIMITERS = %w[head tail].freeze
    MARKER = /\A\s*(?:={2,}|-{2,}|#+)\s*(.*?)\s*(?:={2,}|-{2,})?\s*\z/m
    ECHO_FLAGS = %w[-e -n -en -ne].freeze

    module_function

    # @return [Parsed, nil] nil when the command isn't plain enough to show
    #   as steps
    def parse(command)
      text = command.to_s
      lexer = Lex::Lexer.new(text)
      tokens = lexer.tokens.zip(lexer.spans).map { |token, span| [*token, span] }
      return nil if lexer.unterminated? || tokens.empty?

      bodies = lexer.heredoc_spans.to_h { |doc| [doc[:span], doc[:tag]] }
      raw = split(tokens)
      return nil if raw.nil? || raw.empty?

      steps = raw.map { |op, words| step(text, op, words, bodies) }
      return nil if steps.any?(&:nil?)

      cd, steps = leading_cd(steps, raw)
      steps = labels(limits(steps))
      steps.empty? ? nil : Parsed.new(cd: cd, steps: steps)
    end

    # [[op, word tokens]] split at SPLIT outside parentheses; nil for a
    # control keyword at a command's start, ;; or unbalanced parentheses.
    def split(tokens)
      steps = []
      op = nil
      words = []
      depth = 0
      tokens.each do |token|
        kind, value = token
        if kind == :op && value == "("
          depth += 1
          words << token
        elsif kind == :op && value == ")"
          depth -= 1
          return nil if depth.negative?

          words << token
        elsif kind == :op && depth.zero?
          return nil unless SPLIT.include?(value)

          if words.empty?
            op = value unless value == "\n" # "a;\nb" keeps the ;
          else
            steps << [steps.empty? ? nil : op, words]
            op = value
          end
          words = []
        else
          return nil if keyword?(words, token)

          words << token
        end
      end
      return nil unless depth.zero?

      steps << [steps.empty? ? nil : op, words] unless words.empty?
      steps
    end

    # Whether +token+ is a control keyword where a command starts (the
    # step's first word, or the first after a "(" inside it).
    def keyword?(words, token)
      return false unless token[0] == :word

      at_start = words.empty? || words.last[0] == :op
      at_start && KEYWORDS.include?(token[1])
    end

    # A Step from its tokens: the text from the first to the last token,
    # heredoc bodies cut out.
    def step(text, op, tokens, bodies)
      body = tokens.find { |t| bodies.key?(t.last) }
      shown = tokens.reject { |t| bodies.key?(t.last) }
      from = shown.map { |t| t.last.begin }.min
      to = shown.map { |t| t.last.end }.max
      return nil unless from

      slice = text[from...to]
      heredoc = body && { tag: bodies[body.last], lines: body_lines(text[body.last]) }
      slice, heredoc = inner_heredoc(slice) unless heredoc
      Step.new(text: slice.strip, op: op, heredoc: heredoc)
    end

    # A heredoc inside a $(…) in +slice+ (git commit -m "$(cat <<'EOF' …)"):
    # the slice with the body cut out, and the heredoc; or the slice as is.
    def inner_heredoc(slice)
      return [slice, nil] unless slice.include?("<<")

      at = 0
      while (open = slice.index("$(", at))
        lexer = Lex::Lexer.new(slice[(open + 2)..])
        lexer.tokens
        doc = lexer.heredoc_spans.first
        if doc
          from = open + 2 + doc[:span].begin - 1 # the newline before the body
          to = open + 2 + doc[:span].end
          to += 1 if slice[to] == "\n"
          return [slice[0...from] + slice[to..], { tag: doc[:tag], lines: body_lines(slice[(from + 1)...to]) }]
        end
        at = open + 2
      end
      [slice, nil]
    end

    # The body's line count, its terminator line not counted.
    def body_lines(body_and_tag) = [body_and_tag.to_s.chomp.lines.size - 1, 0].max

    # A first "cd X" step followed by && or ; becomes the cd.
    def leading_cd(steps, raw)
      words = raw.first[1]
      next_op = steps[1]&.op
      plain = words.size == 2 && words.all? { |t| t[0] == :word } && !words[1][1].include?(Lex::SUBST)
      return [nil, steps] unless plain && words[0][1] == "cd" && ["&&", ";"].include?(next_op)

      [words[1][1], [steps[1].with(op: nil), *steps.drop(2)]]
    end

    # A pipeline's last head/tail becomes the limit of the step before it.
    def limits(steps)
      steps.each_with_index.with_object([]) do |(step, i), out|
        limit = step.op == "|" && !out.empty? && out.last.limit.nil? && limit_of(step.text)
        if limit && !["|", "|&"].include?(steps[i + 1]&.op)
          out[-1] = out.last.with(limit: limit)
        else
          out << step
        end
      end
    end

    # "head 20" for "head -n 20" / "head -20" / "head -n20"; "head -c 60";
    # "tail +5"; "head" alone. nil for anything else (tail -f, a file).
    def limit_of(text)
      words = Lex.lex(text)
      return nil unless words.all? { |t| t[0] == :word }

      name, *args = words.map { |t| t[1] }
      return nil unless LIMITERS.include?(name)

      count = case args
              in [] then nil
              in [/\A-\d+\z/ => arg] then arg[1..]
              in [/\A-n\+?\d+\z/ => arg] then arg[2..]
              in ["-n", /\A\+?\d+\z/ => arg] then arg
              in ["-c", /\A\d+\z/ => arg] then "-c #{arg}"
              else return nil
              end
      [name, count].compact.join(" ")
    end

    # A marker echo labels the next step; a bare one goes.
    # A dropped echo's op goes to the step after it (the link from the
    # step before).
    def labels(steps)
      out = []
      label = nil
      op = nil
      steps.each_with_index do |step, i|
        marker = marker_label(step.text)
        if marker.nil? || (!marker.empty? && i == steps.size - 1)
          step = step.with(label: label, op: op || step.op) if op
          out << (out.empty? ? step.with(op: nil) : step)
          label = op = nil
        else
          label = marker unless marker.empty?
          op ||= step.op || "\n"
        end
      end
      out
    end

    # The label of a lone marker echo ("" for a bare marker or an empty
    # echo), nil for any other step.
    def marker_label(text)
      words = Lex.lex(text)
      return nil unless words.all? { |t| t[0] == :word && !t[1].include?(Lex::SUBST) }

      name, *args = words.map { |t| t[1] }
      args.shift while ECHO_FLAGS.include?(args.first)
      return nil unless name == "echo" && args.size <= 1
      return "" if args.empty? || args[0].strip.empty?

      match = MARKER.match(args[0])
      return nil unless match && args[0].strip.match?(/\A(?:={2,}|-{2,}|#)/)

      match[1].strip
    end
  end
end
