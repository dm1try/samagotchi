# frozen_string_literal: true

require "strscan"
require_relative "shell_lex"
require_relative "shell_paths"

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
    #
    # .read_only_but_writes? (the child boundary's) also lets through the
    # writes it can name: a > or >> target, cp's destination and tee's
    # files, each resolved against the dir the command is in by then
    # (ShellPaths::Walk) and accepted by the caller's block. It trusts
    # Walk's dir only where the shell's can't differ: a cd or pushd takes
    # one existing dir, spelt /…, . or .. (no option, +N, -, $, ~ or
    # CDPATH name), and joins beside it are && only (a failed or skipped
    # cd can't be followed by a command that still runs); popd is never
    # accepted, nor is a $ or ~ in a write's target (the call's env may
    # set it).
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
      # A redirection with its target in the same word (>out, 2>>out); not
      # >&file (it is &> spelt the other way).
      REDIRECT_TO = /\A\d*>>?([^&>].*)\z/m
      # Pipe operators: each side runs in a subshell.
      PIPES = ["|", "|&"].freeze
      # Verbs that change the dir ShellPaths::Walk follows.
      DIR_VERBS = %w[cd pushd popd].freeze
      # The joins a group (or the whole command) holding a cd or pushd may
      # use in write mode: after any other a command can run in a dir the
      # cd didn't reach (cd failed, or was skipped by ||).
      DIR_JOINS = ["&&", "|", "|&"].freeze
      # A dir verb's operand the shell resolves as Walk does: absolute, or
      # ./ ../ (CDPATH is not searched for these).
      DIR_OPERAND = %r{\A(?:/|\.\.?(?:/|\z))}

      # The write side of .read_only_but_writes?: the Walk that follows the
      # command's dir and the caller's test for an absolute path it writes.
      Writes = Data.define(:walk, :writable) do
        # +word+ as an absolute path against the current dir, or nil; nil
        # for one with a $ or ~ (the shell may expand them from an env
        # Walk doesn't see, as task_create's env: sets).
        def path(word) = word.include?("$") || word.start_with?("~") ? nil : walk.path(word)

        # Whether a cd or pushd with +args+ lands where Walk says: one
        # operand (DIR_OPERAND) naming an existing dir. popd never does.
        def dir_step?(verb, args)
          return false unless verb != "popd" && args.size == 1 && args.first.match?(DIR_OPERAND)

          dir = path(args.first)
          !dir.nil? && File.directory?(dir)
        end

        def ok?(path) = path ? writable.call(path) == true : false

        # Whether +word+ names a file the command may write.
        def file?(word) = ok?(path(word))
      end

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

      # Whether the command only reads but for writes whose resolved paths
      # the block accepts: > and >> targets, cp's destination (and the
      # files it makes in it) and tee's files. Paths resolve against +cwd+
      # and the dir an earlier cd, pushd or popd moved to; a cd beside a pipe
      # (a subshell's) isn't one Walk can follow, so it is not.
      # @param command [String, nil]
      # @param cwd [String, nil] where the command starts
      # @yieldparam path [String] an absolute path, symlinks not resolved
      # @return [Boolean]
      def read_only_but_writes?(command, cwd:, home: Dir.home, env: ENV, &writable)
        text = command.to_s
        return false if text.strip.empty?

        tokens = ShellLex.lex(text)
        commands = split(tokens, marks: true) or return false
        return false if commands.none?(Array) || !dir_joins_ok?(tokens)

        writes = Writes.new(walk: ShellPaths::Walk.new(cwd, home, env), writable: writable)
        commands.all? { |words| words.is_a?(Symbol) ? writes.walk.step(words) : simple_read_only?(words, writes) }
      rescue ArgumentError, EncodingError
        false
      end

      # The simple commands as [text, specials] word lists; nil when an
      # operator isn't one read-only commands may be joined with. With
      # +marks+, ( and ) stay as :open / :close, and a cd, pushd or popd
      # beside a pipe is nil.
      def split(tokens, marks: false)
        commands = [[]]
        piped = false
        tokens.each do |kind, value, specials|
          if kind == :op
            return nil unless JOINS.include?(value)

            pipe = PIPES.include?(value)
            return nil if marks && (piped || pipe) && dir_verb?(commands.last)

            piped = pipe
            commands << (value == "(" ? :open : :close) if marks && ["(", ")"].include?(value)
            commands << []
          else
            commands.last << [value, specials]
          end
        end
        return nil if marks && piped && dir_verb?(commands.last)

        commands.reject { |words| words.is_a?(Array) && words.empty? }
      end

      def dir_verb?(words) = words.is_a?(Array) && DIR_VERBS.include?(verb_of(words))

      # Whether each group holding a dir verb itself (the whole command,
      # or a ( … ): nested ones are their own) joins with DIR_JOINS only.
      def dir_joins_ok?(tokens)
        scopes = [[false, false]] # [holds a dir verb, has another join]
        words = []
        tokens.each do |kind, value, specials|
          next words << [value, specials] unless kind == :op

          scopes.last[0] ||= dir_verb?(words)
          words = []
          case value
          when "(" then scopes << [false, false]
          when ")"
            dir, other = scopes.pop
            return false if scopes.empty? || (dir && other)
          else scopes.last[1] ||= !DIR_JOINS.include?(value)
          end
        end
        scopes.last[0] ||= dir_verb?(words)
        scopes.none? { |dir, other| dir && other }
      end

      # The first word that is no redirection or its target.
      def verb_of(words)
        target = false
        words.each do |text, specials|
          if target then target = false
          elsif specials.include?(">") then target = text.match?(BARE_REDIRECT)
          else return text
          end
        end
        nil
      end

      # With +writes+ (.read_only_but_writes?) its redirections may write
      # what it accepts, cp and tee count, and the walk takes the command.
      def simple_read_only?(words, writes = nil)
        return false if words.any? { |text, specials| text.include?(ShellLex::SUBST) || !expansion_ok?(text, specials) }

        args = strip_redirects(words, writes) or return false
        return false if writes && DIR_VERBS.include?(args.first) && !writes.dir_step?(args.first, args.drop(1))

        writes&.walk&.step(args)
        verb = args.shift
        return false unless verb&.match?(/\A[a-z][\w.-]*\z/)
        return true if PLAIN.include?(verb)
        return WRITE_CHECKS[verb].call(args, writes) if writes && WRITE_CHECKS[verb]

        check = CHECKS[verb] or return false
        check.call(args)
      end

      # A word may carry a $ only as SAFE_EXPANSION, and no brace expansion.
      def expansion_ok?(text, specials)
        return text.match?(SAFE_EXPANSION) if specials.include?("$")

        !specials.include?("{") && !specials.include?("}")
      end

      # The words with their redirections taken out; nil when one isn't an
      # fd dup, to /dev/null, or (with +writes+) to a file it accepts.
      def strip_redirects(words, writes = nil)
        out = []
        pending = false
        words.each do |text, specials|
          if pending
            return nil unless text == "/dev/null" || (writes && specials.delete("$").empty? && writes.file?(text))

            pending = false
          elsif specials.include?("<")
            return nil
          elsif specials.include?(">")
            next if text.match?(FD_DUP) || text.match?(NULL_REDIRECT)
            next if writes && (m = text.match(REDIRECT_TO)) && !m[1].match?(/[<>]/) && writes.file?(m[1])
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

      SQLITE_OPTIONS = %w[-readonly -safe -json -csv -header -noheader -line -column -box -list -separator -bail
                          -batch -noinit].freeze

      # sqlite3 can still write or run programs unless both safety flags are
      # present. Its options may follow the database name, so check every word.
      def sqlite3(args)
        options = []
        positional = []
        index = 0
        while index < args.length
          arg = args[index]
          if arg == "-separator"
            return false if index + 1 == args.length

            index += 2
          elsif SQLITE_OPTIONS.include?(arg)
            options << arg
            index += 1
          elsif arg.start_with?("-", ".")
            return false
          else
            positional << arg
            index += 1
          end
        end

        options.include?("-readonly") && options.include?("-safe") && positional.size >= 2
      end

      GH_READS = {
        "run" => %w[list view],
        "pr" => %w[list view diff checks],
        "issue" => %w[list view],
        "repo" => %w[view]
      }.freeze

      def gh(args)
        # -w alone or in a bundle of short flags (-cw) opens a browser.
        return false if args.any? { |arg| arg.match?(/\A-[a-zA-Z]*w/) || arg.start_with?("--web") }

        group, action = args
        return false unless GH_READS.fetch(group, []).include?(action)
        return false if group == "pr" && action == "checks" && args.any? { |arg| arg.start_with?("--watch") }

        true
      end

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

      CP_SHORT = "afinpvrRPLHxT"
      CP_LONG = %w[--archive --force --interactive --no-clobber --recursive --verbose --dereference
                   --no-dereference --one-file-system --no-target-directory].freeze
      CP_PRESERVE = /\A--(?:no-)?preserve(?:=[\w,]+)?\z/

      # cp whose destination (the last argument, or -t / --target-directory)
      # and the files it makes in it, when it is a dir, the caller accepts.
      # Only options that copy: no -l/-s (links into the source), --parents
      # or --backup; anything unknown is not.
      def cp(args, writes)
        target = nil
        no_target = false
        positional = []
        rest = args.dup
        until rest.empty?
          arg = rest.shift
          if !arg.start_with?("-") || arg == "-" then positional << arg
          elsif arg == "--" then positional.concat(rest.shift(rest.size))
          elsif (m = arg.match(/\A-([#{CP_SHORT}]*)t(.*)\z/m))
            no_target ||= m[1].include?("T")
            target = m[2].empty? ? rest.shift : m[2]
            return false unless target
          elsif arg == "--target-directory" then target = rest.shift or return false
          elsif (m = arg.match(/\A--target-directory=(.+)\z/m)) then target = m[1]
          elsif arg.match?(/\A-[#{CP_SHORT}]+\z/) then no_target ||= arg.include?("T")
          elsif CP_LONG.include?(arg) || arg.match?(CP_PRESERVE) then no_target ||= arg == "--no-target-directory"
          else return false
          end
        end
        into = !target.nil?
        target ||= positional.pop
        return false if positional.empty? || (into && no_target)

        dest = writes.path(target) or return false
        into ||= !no_target && File.directory?(dest)
        made = into ? positional.map { |src| File.join(dest, File.basename(src)) } : []
        [dest, *made].all? { |path| writes.ok?(path) }
      end

      TEE_OPTIONS = %w[-a --append -i --ignore-interrupts -p].freeze

      # tee whose every file the caller accepts.
      def tee(args, writes)
        files = args.reject { |arg| TEE_OPTIONS.include?(arg) }
        files.all? { |file| !file.start_with?("-") && writes.file?(file) }
      end

      # The verbs that write, for .read_only_but_writes? only: → (args, writes).
      WRITE_CHECKS = { "cp" => method(:cp), "tee" => method(:tee) }.freeze

      CHECKS = {
        "rg" => method(:rg), "find" => method(:find), "tree" => method(:tree), "file" => method(:file),
        "sort" => method(:sort), "uniq" => method(:uniq), "sed" => method(:sed), "awk" => method(:awk),
        "git" => method(:git), "sqlite3" => method(:sqlite3), "gh" => method(:gh)
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

          # Two calls, two fields: each one advances the scanner (pattern, then replacement).
          delimited(delim) && delimited(delim) && @s.skip(/[gpiImM\d]*/) && true # rubocop:disable Lint/BinaryOperatorWithIdenticalOperands
        end

        def transliterate
          delim = @s.getch
          return false if delim.nil? || delim.match?(/[\s\\]/)

          # Source set, then target set: each call advances the scanner.
          delimited(delim) && delimited(delim) # rubocop:disable Lint/BinaryOperatorWithIdenticalOperands
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
