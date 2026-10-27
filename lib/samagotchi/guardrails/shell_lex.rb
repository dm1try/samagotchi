# frozen_string_literal: true

require_relative "data_readers"

module Samagotchi
  module Guardrails
    # A small shell lexer for the guardrails' text checks (ShellGitDirs
    # and the rules' shell matchers): words with quotes and
    # backslashes undone, operators apart, comments dropped, and $(…) or
    # backticks (quoted or not) as one opaque SUBST marker inside a word. A
    # heredoc's body (<<EOF, <<'EOF', <<-EOF) is one word after its <<TAG
    # word and lexing goes on after the terminator line: HEREDOC when cat or
    # tee read it as data (when the command ends at a plain separator,
    # outside any ( or { group), SUBST when an unquoted tag's body holds $(…)
    # or backticks, else the body text itself (a script, as sh -c '…' gives).
    # An unterminated heredoc is no heredoc: the rest is lexed as commands.
    # It never runs anything, and it does its best on odd input (an
    # unbalanced quote).
    module ShellLex
      # Longest first: "&&" before "&", ";;" before ";".
      OPERATORS = ["&&", "||", ";;", "|&", ";", "|", "&", "\n", "(", ")"].freeze
      # What a $(…) or `…` becomes inside a word.
      SUBST = "\0SUBST"
      # What a heredoc body that a data reader reads as data becomes (its
      # command ends at a plain separator, outside any ( or { group).
      HEREDOC = DataReaders::HEREDOC
      # The operators that may follow a data heredoc's command; any other
      # (|, |&, &, (, ), ;;) may hand its output on, and & also starts
      # &>file.
      DATA_ENDS = ["\n", ";", "&&", "||"].freeze
      # A word that is a redirection (>, >>, 2>&1, <).
      REDIRECT = DataReaders::REDIRECT

      # Words and operators ([:word, "x", specials] / [:op, "&&"]). A word's
      # specials are the characters the shell would act on in it, unquoted
      # ("$" also when double-quoted): "$" an expansion, "{" / "}" a brace
      # expansion, ">" / "<" a redirection.
      def self.lex(text)
        Lexer.new(text).tokens
      end

      # Whether +text+ ends inside a quote, a $(…) or a heredoc: its tokens
      # are a best guess.
      def self.unterminated?(text)
        lexer = Lexer.new(text)
        lexer.tokens
        lexer.unterminated?
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

      # Whether an ( or { group is still open at token +at+: a pipe after
      # the group's ) or } takes what the group prints. The counters never go
      # below 0 (a case pattern's "x)" closes nothing); ((…)) arithmetic and
      # <(…) / >(…) count as open parens (the conservative reading).
      def self.in_group?(tokens, at)
        parens = 0
        braces = 0
        tokens[0...at].each do |kind, value|
          if kind == :op
            parens += 1 if value == "("
            parens -= 1 if value == ")" && parens.positive?
          elsif value == "{"
            braces += 1
          elsif value == "}" && braces.positive?
            braces -= 1
          end
        end
        parens.positive? || braces.positive?
      end

      # +text+ as code: the lines of each heredoc body its command only reads
      # as data (DataReaders) cut out, the <<TAG word and the terminator line
      # kept as written. This is what a rule's command: reads. A text the
      # lexer isn't sure of (unterminated) comes back as it was, and so does
      # one it can't read: the safe default. +keep_written+ false cuts every
      # data body, a cat or tee writing it to a file too (a pair turn's check:
      # text written to a file is data; where it goes is checked apart).
      def self.code_text(text, keep_written: true)
        lexer = Lexer.new(text)
        tokens = lexer.tokens
        return text if lexer.unterminated?

        bodies = lexer.heredoc_spans.map { |doc| doc[:span] }
        cuts = []
        redirected = false
        each_command(tokens) do |indices|
          words = indices.map { |i| tokens[i][1] }
          indices.each_with_index do |i, position|
            kind, value, = tokens[i]
            next unless kind == :word

            span = lexer.spans[i]
            cut = if bodies.include?(span)
                    body_cut(text, span, words, redirected, keep_written) if value == HEREDOC
                  elsif value == SUBST
                    substitution_cut(text, tokens, i, span, words, position)
                  end
            cuts << cut if cut
          end
          redirected ||= exec_redirect?(tokens, indices, words)
        end
        cuts.sort_by { |span, _| -span.begin }.each_with_object(+text) do |(span, replacement), out|
          out[span] = replacement
        end
      rescue ArgumentError, EncodingError
        text
      end

      # The token indices of each simple command, its operators left out.
      def self.each_command(tokens)
        current = []
        tokens.each_with_index do |(kind, _value, *_rest), i|
          if kind == :op
            yield current unless current.empty?
            current = []
          else
            current << i
          end
        end
        yield current unless current.empty?
      end
      private_class_method :each_command

      # [span, what it becomes] for a data heredoc's body at +span+ (its
      # command's +words+), or nil when the body stays in the code text: a
      # cat or tee writing a file may be run later (D1), and so may one
      # printing after an earlier exec sent the shell's output to a file
      # (+redirected+).
      def self.body_cut(text, span, words, redirected, keep_written = true)
        return nil if keep_written && !cut_body?(words, redirected)

        [span, terminator_line(text[span])]
      end
      private_class_method :body_cut

      # Whether a body a data reader reads leaves the code text: a cat or tee
      # sending it to a file keeps it (D1), as does any cat or tee once an
      # exec redirected the shell's output (+redirected+: its stdout, or the
      # fd a >&3 names, may be a file); a body any other command reads as
      # data is one the lexer's data_sink? approved.
      def self.cut_body?(words, redirected)
        verb = DataReaders.command_word(words)
        return true unless DataReaders::SINKS.include?(File.basename(verb.to_s))

        !redirected && !DataReaders.writes_file?(words)
      end
      private_class_method :cut_body?

      # Whether the simple command at +indices+ may be an exec that redirects
      # the shell's own output to a file (exec >run.sh, exec 3>run.sh,
      # exec {fd}>run.sh, exec 3<>run.sh): what a later cat or tee prints may
      # land there. Any exec word counts, not only the command word ({ exec
      # …; }, then exec …, command exec …, a function's body), and so does an
      # exec backgrounded (exec &>run.sh, which the lexer reads as "exec &"
      # and ">run.sh"): the conservative reading.
      def self.exec_redirect?(tokens, indices, words)
        return false unless words.include?("exec")

        following = tokens[indices.last + 1]
        DataReaders.output_file?(words) || following == [:op, "&"]
      end
      private_class_method :exec_redirect?

      # [span, what it becomes] for the body of a "$(cat <<'EOF' … EOF)" given
      # as a message (-m, --body, …) of a data reader (D2), or nil: eval,
      # bash -c, a command piped on and a body that runs stay.
      def self.substitution_cut(text, tokens, index, span, words, position)
        return nil unless data_end?(tokens, index)
        return nil if in_group?(tokens, index)
        return nil unless DataReaders.message_arg?(words, position)

        raw = text[span]
        dollar = raw.start_with?("\"$(") ? 1 : 0
        return nil unless raw[dollar, 2] == "$("

        inner = raw[(dollar + 2)..]
        inner_lexer = Lexer.new(inner)
        first = inner_lexer.tokens.first(5)
        return nil unless message_heredoc?(first)

        inner_span = inner_lexer.spans[2]
        return nil unless inner_span

        start = span.begin + dollar + 2
        cut = ((start + inner_span.begin)...(start + inner_span.end))
        [cut, terminator_line(text[cut])]
      end
      private_class_method :substitution_cut

      # Whether the command holding token +index+ ends at nil or a plain
      # separator (not piped on: what it prints is not run).
      def self.data_end?(tokens, index)
        next_op = (tokens[(index + 1)..] || []).find { |token| token[0] == :op }
        next_op.nil? || DATA_ENDS.include?(next_op[1])
      end
      private_class_method :data_end?

      # Whether the tokens inside a $(…) are cat <<TAG and a data body, and
      # the substitution closes right after.
      def self.message_heredoc?(first)
        first.size == 5 && first[0][0..1] == [:word, "cat"] &&
          first[1][0] == :word && first[1][1].start_with?("<<") &&
          first[2][0..1] == [:word, HEREDOC] && first[3] == [:op, "\n"] && first[4] == [:op, ")"]
      end
      private_class_method :message_heredoc?

      # +raw+ (a body and its terminator line) as its terminator line alone.
      def self.terminator_line(raw)
        line = raw.rindex("\n")
        line ? raw[(line + 1)..] : raw
      end
      private_class_method :terminator_line

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

        # Whether the command the heredoc at token +at+ is in reads it as data
        # (DataReaders.data_reader?: cat, tee, git commit -F -, gh …), ends at
        # a plain separator (DATA_ENDS: not piped on, backgrounded or handed to
        # a process substitution) and sits outside any ( or { group (whose
        # output a pipe after the group's ) or } would take).
        def data_sink?(at)
          start = at
          start -= 1 while start.positive? && @tokens[start - 1][0] == :word
          following = @tokens[at..] || []
          next_op = following.index { |t| t[0] == :op }
          ends = next_op.nil? || DATA_ENDS.include?(following[next_op][1])
          words = @tokens[start...at].map { |t| t[1] }
          words += @tokens[at...(next_op ? at + next_op : @tokens.size)].map { |t| t[1] }
          DataReaders.data_reader?(words) && ends && !in_group?(at)
        end

        # Whether an ( or { group is still open at token +at+.
        def in_group?(at) = ShellLex.in_group?(@tokens, at)
      end
    end
  end
end
