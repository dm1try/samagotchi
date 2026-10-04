# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # A small shell lexer for the guardrails' text checks (ShellGitDirs
    # and the rules' shell matchers): words with quotes and
    # backslashes undone, operators apart, comments dropped, and $(…) or
    # backticks (quoted or not) as one opaque SUBST marker inside a word. A
    # heredoc's body (<<EOF, <<'EOF', <<-EOF) is one word after its <<TAG
    # word and lexing goes on after the terminator line: HEREDOC when cat or
    # tee read it as data, SUBST when an unquoted tag's body holds $(…) or
    # backticks, else the body text itself (a script, as sh -c '…' gives).
    # An unterminated heredoc is no heredoc: the rest is lexed as commands.
    # It never runs anything, and it does its best on odd input (an
    # unbalanced quote).
    module ShellLex
      # Longest first: "&&" before "&", ";;" before ";".
      OPERATORS = ["&&", "||", ";;", "|&", ";", "|", "&", "\n", "(", ")"].freeze
      # What a $(…) or `…` becomes inside a word.
      SUBST = "\0SUBST"
      # What a heredoc body that cat or tee read as data becomes.
      HEREDOC = "\0HEREDOC"
      # Commands that read a heredoc as data (when not piped on).
      DATA_SINKS = %w[cat tee].freeze
      # A word that is a redirection (>, >>, 2>&1, <).
      REDIRECT = /\A\d*[<>]/

      # Words and operators ([:word, "x", specials] / [:op, "&&"]). A word's
      # specials are the characters the shell would act on in it, unquoted
      # ("$" also when double-quoted): "$" an expansion, "{" / "}" a brace
      # expansion, ">" / "<" a redirection.
      def self.lex(text)
        Lexer.new(text).tokens
      end

      # lex's tokens, each with the range of +text+ it was read from
      # appended ([:word, "x", specials, 0...1] / [:op, "&&", 2...4]), for a
      # display that slices the original text. A heredoc body's range is
      # the body and its terminator line. lex itself is unchanged by this.
      def self.lex_with_spans(text)
        lexer = Lexer.new(text)
        lexer.tokens.zip(lexer.spans).map { |token, span| [*token, span] }
      end

      # The token stream split at operators into word lists; ( and ) become
      # :open / :close markers.
      def self.simple_commands(tokens)
        commands = [[]]
        tokens.each do |kind, value|
          if kind == :op
            commands << :open if value == "("
            commands << :close if value == ")"
            commands << []
          else
            commands.last << value
          end
        end
        commands.reject { |c| c.is_a?(Array) && c.empty? }
      end

      # A hand-written shell lexer: quotes, backslashes, comments, $(…) and
      # backticks (an opaque marker inside the word), redirections kept in
      # their word (2>&1 doesn't split on &), operators.
      class Lexer
        def initialize(text)
          @s = text
          @i = 0
          @tokens = []
          @spans = []
          @start = 0
          @word = +""
          @specials = +""
          @in_word = false
          @heredocs = []
          @heredoc_spans = []
          @unterminated = false
        end

        def tokens
          step while @i < @s.size
          flush
          @unterminated = true unless @heredocs.empty?
          @tokens
        end

        # Each token's range in the text, in step with #tokens (after it).
        attr_reader :spans

        # The heredocs read ({tag:, span:}, the body and its terminator
        # line), after #tokens.
        attr_reader :heredoc_spans

        # Whether a quote, $(…), backtick or heredoc was left open (after
        # #tokens): the lexer's best effort, not the shell's reading.
        def unterminated? = @unterminated

        private

        def step
          c = @s[@i]
          case c
          when "\\" then add(@s[@i + 1].to_s, 2)
          when "'" then single_quote
          when '"' then double_quote
          when "`" then backtick
          when "$" then @s[@i + 1] == "(" ? substitution : special(c)
          when "#" then @in_word ? add(c, 1) : comment
          when ">", "<" then redirection
          when " ", "\t" then flush && (@i += 1)
          else operator_or_char(c)
          end
        end

        def add(text, advance)
          @start = @i unless @in_word
          @word << text
          @in_word = true
          @i += advance
        end

        # A character the shell acts on, kept in the word and noted.
        def special(char)
          @specials << char unless @specials.include?(char)
          add(char, 1)
        end

        def flush
          if @in_word
            @tokens << [:word, @word.dup, @specials.dup]
            @spans << (@start...[@i, @s.size].min)
          end
          @word.clear
          @specials.clear
          @in_word = false
          true
        end

        def single_quote
          close = @s.index("'", @i + 1)
          @unterminated ||= close.nil?
          close ||= @s.size
          add(@s[(@i + 1)...close].to_s, close + 1 - @i)
        end

        def double_quote
          @start = @i unless @in_word
          @i += 1
          @in_word = true
          while @i < @s.size && @s[@i] != '"'
            if @s[@i] == "\\" && @i + 1 < @s.size
              @word << @s[@i + 1]
              @i += 2
            elsif @s[@i] == "`" then backtick
            elsif @s[@i] == "$" && @s[@i + 1] == "(" then substitution
            elsif @s[@i] == "$" then special("$")
            else
              @word << @s[@i]
              @i += 1
            end
          end
          @unterminated = true if @i >= @s.size
          @i += 1
        end

        def backtick
          close = @s.index("`", @i + 1)
          @unterminated ||= close.nil?
          close ||= @s.size
          add(SUBST, close + 1 - @i)
        end

        # From $( to the ) that closes it, as one SUBST. A quote or a
        # heredoc body inside it is skipped over: a ) in one of those
        # doesn't close the substitution.
        def substitution
          depth = 0
          j = @i + 1
          loop do
            break if j >= @s.size

            c = @s[j]
            if ["'", '"'].include?(c)
              j = quote_end(j)
            elsif c == "("
              depth += 1
              j += 1
            elsif c == ")"
              depth -= 1
              j += 1
              break if depth.zero?
            elsif @s[j, 2] == "<<"
              j = substitution_heredoc(j)
            else
              j += 1
            end
          end
          @unterminated = true unless depth.zero?
          add(SUBST, j - @i)
        end

        # The index after the quote starting at +j+, a backslash in a double
        # quote escaping the next character; the text's end when it is never
        # closed.
        def quote_end(j)
          quote = @s[j]
          k = j + 1
          while k < @s.size
            if quote == '"' && @s[k] == "\\" then k += 2
            elsif @s[k] == quote then return k + 1
            else k += 1
            end
          end
          k
        end

        # From a << at +j+ inside a $(…) past its body's terminator line
        # (nothing is lexed: the body is only stepped over), or on to the
        # next character when no tag follows or the terminator never comes
        # (a << that is no heredoc, as arithmetic's 1<<3, stays scanned).
        def substitution_heredoc(j)
          dash = @s[j + 2] == "-"
          k = j + (dash ? 3 : 2)
          k += 1 while [" ", "\t"].include?(@s[k])
          tag, _quoted, stop = heredoc_tag(k)
          return j + 1 if tag.empty?

          eol = @s.index("\n", stop)
          return j + 1 if eol.nil?

          k = eol + 1
          while k < @s.size
            eol = @s.index("\n", k) || @s.size
            line = @s[k...eol]
            line = line.sub(/\A\t+/, "") if dash
            return [eol + 1, @s.size].min if line == tag

            k = eol + 1
          end
          j + 1
        end

        def comment
          @i = @s.index("\n", @i) || @s.size
        end

        # >, >>, 2>&1, &>, <, <<<: kept in the word (the walk drops them).
        # << starts a heredoc.
        def redirection
          return add("<<<", 3) if @s[@i, 3] == "<<<"
          return if @s[@i, 2] == "<<" && heredoc

          special(@s[@i])
          add(@s[@i], 1) while @i < @s.size && @s[@i].match?(/[&\d>-]/) && @word.end_with?(">")
        end

        def operator_or_char(char)
          op = OPERATORS.find { |o| @s[@i, o.size] == o }
          return special(char) if ["{", "}"].include?(char)
          return add(char, 1) unless op

          if op == "&" && @word.match?(/\d*>\z/)
            add(op, 1)
          else
            flush
            @tokens << [:op, op]
            @spans << (@i...(@i + op.size))
            @i += op.size
            bodies if op == "\n" && !@heredocs.empty?
          end
        end

        # <<TAG, <<-TAG, <<'TAG', << "TAG": its own word, the body noted to
        # be read after the line ends. False (nothing read) without a tag.
        def heredoc
          dash = @s[@i + 2] == "-"
          j = @i + (dash ? 3 : 2)
          j += 1 while [" ", "\t"].include?(@s[j])
          tag, quoted, stop = heredoc_tag(j)
          return false if tag.empty?

          flush unless @word.match?(/\A\d*\z/)
          special("<")
          @word << "<" << (dash ? "-" : "") << tag
          @i = stop
          flush
          @heredocs << { tag: tag, dash: dash, quoted: quoted, at: @tokens.size }
          true
        end

        # The tag starting at +j+ with quotes and backslashes undone, whether
        # any were there, and where it ends.
        def heredoc_tag(j)
          tag = +""
          quoted = false
          while j < @s.size && !@s[j].match?(/[\s;&|<>()]/)
            if ["'", '"'].include?(@s[j])
              close = @s.index(@s[j], j + 1) or return ["", false, j]
              tag << @s[(j + 1)...close]
              j = close + 1
              quoted = true
            elsif @s[j] == "\\"
              tag << @s[j + 1].to_s
              j += 2
              quoted = true
            else
              tag << @s[j]
              j += 1
            end
          end
          [tag, quoted, j]
        end

        # After a line with heredocs: each body in order, up to its
        # terminator line, as one word in its command. Unterminated: none
        # are, and the rest is lexed as commands.
        def bodies
          heredocs = @heredocs
          @heredocs = []
          pos = @i
          start = pos
          read = []
          heredocs.each do |doc|
            body, pos = body(doc, pos)
            break unless body

            read << [doc, body, start...(@s[pos - 1] == "\n" ? pos - 1 : pos)]
            start = pos
          end
          @unterminated ||= read.size < heredocs.size
          return if read.size < heredocs.size

          read.reverse_each do |doc, body, span|
            @tokens.insert(doc[:at], [:word, body_word(doc, body), ""])
            @spans.insert(doc[:at], span)
          end
          read.each { |doc, _body, span| @heredoc_spans << { tag: doc[:tag], span: span } }
          @i = pos
        end

        # The body from +pos+ and where lexing goes on, or nil.
        def body(doc, pos)
          start = pos
          while pos < @s.size
            eol = @s.index("\n", pos) || @s.size
            line = @s[pos...eol]
            line = line.sub(/\A\t+/, "") if doc[:dash]
            return [@s[start...pos], [eol + 1, @s.size].min] if line == doc[:tag]

            pos = eol + 1
          end
          nil
        end

        def body_word(doc, body)
          return SUBST if !doc[:quoted] && body.match?(/\$\(|`/)
          return HEREDOC if data_sink?(doc[:at])

          body
        end

        # Whether the command the heredoc at token +at+ is in is cat or tee
        # and not piped into another command.
        def data_sink?(at)
          start = at
          start -= 1 while start.positive? && @tokens[start - 1][0] == :word
          verb = command_word(@tokens[start...at])
          next_op = @tokens[at..].find { |t| t[0] == :op }
          DATA_SINKS.include?(File.basename(verb.to_s)) && !["|", "|&"].include?(next_op&.dig(1))
        end

        # The command word among the words before a heredoc's: the NAME=
        # words and the redirections dropped, and with a redirection written
        # with a space (> /tmp/x) its target word too.
        def command_word(words)
          i = 0
          while i < words.size
            word = words[i][1]
            if word.match?(REDIRECT)
              i += 1 if word.match?(/\A\d*[<>]{1,2}\z/)
            elsif !word.match?(/\A[A-Za-z_]\w*=/)
              return word
            end
            i += 1
          end
          nil
        end
      end
    end
  end
end
