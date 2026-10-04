# frozen_string_literal: true

require "strscan"
require_relative "shell_lex"

module Samagotchi
  module Guardrails
    # Whether a shell command only reads: every simple command in it (split
    # at ;, &&, ||, |, newlines and ( … )) starts with an allowlisted verb,
    # gives it no option that writes or runs something, and redirects
    # nothing but to /dev/null or another fd. A rule with skip_read_only
    # lets such a command through.
    #
    # It errs towards "not read-only": anything it can't tell is not.
    # $(…) or backticks, an env assignment or prefix (env, sudo, xargs,
    # sh -c, eval, timeout, …), a background &, a $ expansion other than
    # $HOME / the XDG dirs / $TMPDIR / $PWD at a word's start, a brace
    # expansion, a < or << redirection, a path to a verb (/bin/ls), and
    # less/more/vim (they run commands) are all not read-only.
    module ReadOnlyShell
      # Operators that join read-only commands (no &, no ;;).
      JOINS = ["&&", "||", ";", "|", "|&", "\n", "(", ")"].freeze
      # A $ expansion allowed at a word's start (the user's own dirs);
      # nothing after it may expand again.
      SAFE_EXPANSION = %r{\A\$(?:\{(?:HOME|XDG_\w+|TMPDIR|PWD)\}|(?:HOME|XDG_[A-Z_]+|TMPDIR|PWD)\b)(?=/|\z)[^${}]*\z}
      # fd dups and closes: 2>&1, >&2, 1>&-.
      FD_DUP = /\A\d*>&(?:\d+|-)\z/
      # A redirection to /dev/null in one word, or its operator alone (the
      # target follows).
      NULL_REDIRECT = %r{\A\d*>>?/dev/null\z}
      BARE_REDIRECT = /\A\d*>>?\z/

      # Verbs that only read whatever their options: → nil. The others
      # check their arguments.
      PLAIN = %w[ls cat head tail wc stat du pwd echo printf basename dirname realpath readlink cut tr nl diff cmp
                 grep egrep fgrep true false cd pushd popd which].freeze

      module_function

      # @param command [String, nil]
      # @return [Boolean]
      def read_only?(command)
        text = command.to_s
        return false if text.strip.empty?

        commands = split(ShellLex.lex(text)) or return false
        !commands.empty? && commands.all? { |words| simple_read_only?(words) }
      rescue ArgumentError, EncodingError
        false
      end

      # The simple commands as [text, specials] word lists; nil when an
      # operator isn't one read-only commands may be joined with.
      def split(tokens)
        commands = [[]]
        tokens.each do |kind, value, specials|
          if kind == :op
            return nil unless JOINS.include?(value)

            commands << []
          else
            commands.last << [value, specials]
          end
        end
        commands.reject(&:empty?)
      end

      def simple_read_only?(words)
        return false if words.any? { |text, specials| text.include?(ShellLex::SUBST) || !expansion_ok?(text, specials) }

        args = strip_redirects(words) or return false
        verb = args.shift
        return false unless verb&.match?(/\A[a-z][\w.-]*\z/)
        return true if PLAIN.include?(verb)

        check = CHECKS[verb] or return false
        check.call(args)
      end

      # A word may carry a $ only as SAFE_EXPANSION, and no brace expansion.
      def expansion_ok?(text, specials)
        return text.match?(SAFE_EXPANSION) if specials.include?("$")

        !specials.include?("{") && !specials.include?("}")
      end

      # The words with their redirections taken out; nil when one isn't an
      # fd dup or to /dev/null.
      def strip_redirects(words)
        out = []
        pending = false
        words.each do |text, specials|
          if pending
            return nil unless text == "/dev/null"

            pending = false
          elsif specials.include?("<")
            return nil
          elsif specials.include?(">")
            next if text.match?(FD_DUP) || text.match?(NULL_REDIRECT)
            return nil unless text.match?(BARE_REDIRECT)

            pending = true
          else
            out << text
          end
        end
        pending ? nil : out
      end

      # A short option group ("-rf") that holds +char+.
      def short_has?(arg, char) = arg.match?(/\A-[^-]/) && arg.include?(char)

      def rg(args) = args.none? { |a| a.start_with?("--pre") }

      FIND_ACTIONS = %w[-delete -exec -execdir -ok -okdir -fprint -fprint0 -fprintf -fls].freeze

      def find(args) = args.none? { |a| FIND_ACTIONS.any? { |action| a.start_with?(action) } }

      # tree -o FILE writes, -R writes 00Tree.html files.
      def tree(args) = args.none? { |a| a.start_with?("--output") || short_has?(a, "o") || short_has?(a, "R") }

      # file -C compiles a magic file.
      def file(args) = args.none? { |a| a.start_with?("--compile") || short_has?(a, "C") }

      def sort(args)
        args.none? { |a| a.start_with?("--output", "--compress-program") || short_has?(a, "o") }
      end

      # uniq IN OUT writes OUT.
      def uniq(args) = args.reject { |a| a.start_with?("-") }.size <= 1

      SED_FLAGS = /\A-[nErsuz]+\z/
      SED_LONG = %w[--quiet --silent --regexp-extended --separate --unbuffered --null-data --posix --debug
                    --sandbox].freeze

      # sed without -i/-f, whose scripts only print, delete, substitute
      # (no w or e flag) and the like (SedScript). GNU sed reads options
      # after the file names too (sed 1p f -i), so every word is checked.
      def sed(args)
        scripts = []
        positional = []
        rest = args.dup
        until rest.empty?
          arg = rest.shift
          if !arg.start_with?("-") || arg == "-" then positional << arg
          elsif arg == "--" then positional.concat(rest.shift(rest.size))
          elsif arg == "-e" || arg.match?(/\A-[nErsuz]*e\z/) then scripts << rest.shift.to_s
          elsif (m = arg.match(/\A-[nErsuz]*e(.+)\z/m)) then scripts << m[1]
          elsif (m = arg.match(/\A--expression=(.*)\z/m)) then scripts << m[1]
          elsif arg.match?(SED_FLAGS) || SED_LONG.include?(arg) then next
          else return false
          end
        end
        if scripts.empty?
          return false if positional.empty?

          scripts << positional.first
        end
        scripts.all? { |script| SedScript.new(script).read_only? }
      end

      # awk with no program file or library, whose program has no output
      # redirection, pipe, getline, system() or @include.
      def awk(args)
        rest = args.dup
        program = nil
        until rest.empty?
          arg = rest.shift
          if ["-F", "-v"].include?(arg) then rest.shift
          elsif arg.match?(/\A-[Fv]./m) then next
          elsif arg == "--" then program = rest.shift
          elsif arg.start_with?("-") then return false
          else program = arg
          end
          break if program
        end
        return false if program.nil?

        !program.match?(/>(?!=)|\||\bsystem\b|\bgetline\b|\bclose\b|@/)
      end

      GIT_GLOBALS = %w[--no-pager -P --no-optional-locks].freeze
      GIT_READS = %w[log show diff status rev-parse rev-list ls-files ls-tree cat-file describe shortlog blame grep
                     merge-base name-rev show-ref count-objects whatchanged].freeze
      # Options that write a file or run a program from a read.
      GIT_DENY = ["--ext-diff", "--output", "--open-files-in-pager", "-O", "--textconv"].freeze
      GIT_BRANCH_LIST = %w[-a -r -v -vv --all --remotes --verbose --list -l --show-current --merged --no-merged
                           --contains --no-contains --points-at --color --no-color --column --no-column
                           --ignore-case -i].freeze
      # These make git branch list (the words after them are patterns).
      GIT_BRANCH_LISTING = %w[--list -l --merged --no-merged --contains --no-contains --points-at].freeze

      # Read-only git: -C and a few harmless globals, then a reading
      # subcommand, without an option that writes or runs something.
      def git(args)
        rest = args.dup
        while (arg = rest.first)&.start_with?("-")
          rest.shift
          if arg == "-C" then rest.shift
          elsif !GIT_GLOBALS.include?(arg) then return false
          end
        end
        sub = rest.shift or return false
        return false if rest.any? { |a| GIT_DENY.any? { |deny| a.start_with?(deny) } }

        case sub
        when "grep" then rest.none? { |a| short_has?(a, "O") }
        when *GIT_READS then true
        when "branch" then git_branch_list?(rest)
        when "stash" then %w[list show].include?(rest.first)
        when "worktree" then rest.first == "list"
        when "remote" then rest.empty? || rest.all? { |a| %w[-v --verbose].include?(a) } || rest.first == "get-url"
        when "tag" then rest.empty? || %w[-l --list].include?(rest.first)
        when "reflog" then rest.none? { |a| %w[expire delete drop write].include?(a) }
        else false
        end
      end

      def git_branch_list?(args)
        options = args.select { |a| a.start_with?("-") }
        return false unless options.all? { |a| GIT_BRANCH_LIST.include?(a) || a.match?(/\A--(sort|format|merged|no-merged|contains|no-contains|points-at|color|column)=/) }

        names = args.size - options.size
        names.zero? || options.any? { |a| GIT_BRANCH_LISTING.any? { |listing| a == listing || a.start_with?("#{listing}=") } }
      end

      CHECKS = {
        "rg" => method(:rg), "find" => method(:find), "tree" => method(:tree), "file" => method(:file),
        "sort" => method(:sort), "uniq" => method(:uniq), "sed" => method(:sed), "awk" => method(:awk),
        "git" => method(:git)
      }.freeze

      # A sed script parsed far enough to tell that it only reads: its
      # commands are among the reading ones, s/// has no w or e flag, and
      # nothing it can't parse.
      class SedScript
        # Commands without arguments that only read or print.
        SIMPLE = "pPdDnNgGhHxzlFv="
        # Commands that take a label (to the end of the command).
        LABELED = "btT:"

        def initialize(text)
          @s = StringScanner.new(text)
        end

        def read_only?
          loop do
            skip_space_and_separators
            return true if @s.eos?
            return false unless command
          end
        rescue ArgumentError
          false
        end

        private

        def skip_space_and_separators
          @s.skip(/[\s;]*/)
          @s.skip(/#[^\n]*/) && skip_space_and_separators
        end

        def command
          address && @s.skip(/\s*/)
          address if @s.skip(/,\s*/)
          @s.skip(/!\s*/)
          char = @s.getch or return false
          ok = if SIMPLE.include?(char) then true
               elsif "qQ".include?(char) then @s.skip(/\s*\d*/) || true
               elsif LABELED.include?(char) then @s.skip(/[^;\n}]*/) || true
               elsif char == "{" then return true
               elsif char == "}" then true
               elsif char == "s" then substitute
               elsif char == "y" then transliterate
               else false
               end
          ok && @s.skip(/[ \t]*/) && (@s.eos? || @s.check(/[;\n}#]/))
        end

        # A line number (N, N~M, +N, ~N), $, /re/ or \cREc, with I/M flags.
        def address
          return true if @s.skip(/\d+(~\d+)?|\$|[+~]\d+/)

          if @s.skip(%r{/})
            delimited("/") && (@s.skip(/[IM]*/) || true)
          elsif @s.skip(/\\/)
            delim = @s.getch or return false
            delimited(delim) && (@s.skip(/[IM]*/) || true)
          else
            false
          end
        end

        def substitute
          delim = @s.getch
          return false if delim.nil? || delim.match?(/[\s\\]/)

          delimited(delim) && delimited(delim) && @s.skip(/[gpiImM\d]*/) && true
        end

        def transliterate
          delim = @s.getch
          return false if delim.nil? || delim.match?(/[\s\\]/)

          delimited(delim) && delimited(delim)
        end

        # Up to the next unescaped +delim+ (consumed); false at the end.
        def delimited(delim)
          until @s.eos?
            char = @s.getch
            if char == "\\" then @s.getch
            elsif char == delim then return true
            end
          end
          false
        end
      end
    end
  end
end
