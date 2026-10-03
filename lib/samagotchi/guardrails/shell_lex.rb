# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # A small shell lexer for the guardrails' text checks (ShellGitDirs
    # and the rules' shell matchers): words with quotes and
    # backslashes undone, operators apart, comments dropped, and $(…) or
    # backticks (quoted or not) as one opaque SUBST marker inside a word. It never runs
    # anything, and it does its best on odd input (an unbalanced quote).
    module ShellLex
      # Longest first: "&&" before "&", ";;" before ";".
      OPERATORS = ["&&", "||", ";;", "|&", ";", "|", "&", "\n", "(", ")"].freeze
      # What a $(…) or `…` becomes inside a word.
      SUBST = "\0SUBST"
      # A word that is a redirection (>, >>, 2>&1, <).
      REDIRECT = /\A\d*[<>]/

      # Words and operators ([:word, "x", specials] / [:op, "&&"]). A word's
      # specials are the characters the shell would act on in it, unquoted
      # ("$" also when double-quoted): "$" an expansion, "{" / "}" a brace
      # expansion, ">" / "<" a redirection.
      def self.lex(text)
        Lexer.new(text).tokens
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
          @word = +""
          @specials = +""
          @in_word = false
        end

        def tokens
          step while @i < @s.size
          flush
          @tokens
        end

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
          @tokens << [:word, @word.dup, @specials.dup] if @in_word
          @word.clear
          @specials.clear
          @in_word = false
          true
        end

        def single_quote
          close = @s.index("'", @i + 1) || @s.size
          add(@s[(@i + 1)...close].to_s, close + 1 - @i)
        end

        def double_quote
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
          @i += 1
        end

        def backtick
          close = @s.index("`", @i + 1) || @s.size
          add(SUBST, close + 1 - @i)
        end

        def substitution
          depth = 0
          j = @i + 1
          loop do
            depth += 1 if @s[j] == "("
            depth -= 1 if @s[j] == ")"
            j += 1
            break if depth.zero? || j >= @s.size
          end
          add(SUBST, j - @i)
        end

        def comment
          @i = @s.index("\n", @i) || @s.size
        end

        # >, >>, 2>&1, &>, <, <<: kept in the word (the walk drops them).
        def redirection
          special(@s[@i])
          add(@s[@i], 1) while @i < @s.size && @s[@i].match?(/[&\d>-]/) && @word.match?(/>\z/)
        end

        def operator_or_char(char)
          op = OPERATORS.find { |o| @s[@i, o.size] == o }
          return special(char) if char == "{" || char == "}"
          return add(char, 1) unless op

          if op == "&" && @word.match?(/\d*>\z/)
            add(op, 1)
          else
            flush
            @tokens << [:op, op]
            @i += op.size
          end
        end
      end
    end
  end
end
