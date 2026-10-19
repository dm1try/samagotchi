# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # Which shell commands read their stdin as data and never run it: cat and
    # tee (to stdout), and a git or gh command taking its message from stdin.
    # Pure word predicates over one simple command's words (the lexer's
    # ShellLex). Everything else is an unknown consumer and stays matched.
    module DataReaders
      # Commands that print what they read.
      SINKS = %w[cat tee].freeze
      # What a heredoc body that a data reader reads becomes (the same value
      # as ShellLex::HEREDOC).
      HEREDOC = "\0HEREDOC"
      # A word that is a redirection (>, >>, 2>&1, <; the same as
      # ShellLex::REDIRECT).
      REDIRECT = /\A\d*[<>]/
      # git's global options that take the next word.
      GIT_OPTIONS_WITH_VALUE = %w[-C -c --git-dir --work-tree --namespace].freeze
      # A >& target that names an fd instead of a file: a number or -.
      FD_TARGET = /\A(\d+|-)\z/

      module_function

      # The command word among a simple command's words: the NAME= words and
      # the redirections dropped, and with a redirection written with a space
      # (> /tmp/x) its target word too. nil when there is none.
      def command_word(words)
        index = command_index(words)
        words[index] if index
      end

      # Where command_word's word is in +words+ (nil when there is none).
      def command_index(words)
        each_argument_index(words).find { |i| !assignment?(words[i]) }
      end

      # Each index of +words+ from +from+ on that is no redirection and no
      # spaced redirection's target (the "/tmp/x" of "> /tmp/x"); an
      # Enumerator without a block.
      def each_argument_index(words, from = 0)
        return enum_for(:each_argument_index, words, from) unless block_given?

        i = from
        while i < words.size
          word = words[i]
          if word.match?(REDIRECT)
            i += word.match?(/\A\d*[<>]{1,2}\z/) ? 2 : 1
            next
          end
          yield i
          i += 1
        end
      end

      # Whether a word is a NAME=value assignment.
      def assignment?(word)
        word.match?(/\A[A-Za-z_]\w*=/)
      end

      # Whether a cat or tee command sends its output to a file (a file
      # written can be run later): a stdout redirection whose target isn't
      # /dev/null, a dangling >, or a tee argument that is no option,
      # redirection, heredoc or /dev/null.
      def writes_file?(words)
        return true if stdout_file?(words)

        File.basename(command_word(words).to_s) == "tee" && tee_file?(words)
      end

      # Whether one of +words+ sends stdout to a file: a >, >>, 1>, 1>>, >& or
      # 1>& redirection (its target in the word, or in the next word when the
      # operator ends it) whose target names a file and isn't /dev/null. A dup
      # to an fd writes no file: >&2, >&-, 2>&1, and a spaced ">& 2" or
      # ">& -". A >& with any other target does write one: bash reads
      # ">& file" and ">&file" as "&>file".
      def stdout_file?(words)
        redirects_to_file?(words, /\A1?(>>?)(&?)(.*)\z/m)
      end

      # Whether one of +words+ sends any fd's output to a file (3>run.sh,
      # 2>>log, {fd}>run.sh, 3<>run.sh as well as stdout_file?'s forms),
      # /dev/null and fd dups left out as there.
      def output_file?(words)
        redirects_to_file?(words, /\A(?:\d*|\{\w+\})(>>?|<>)(&?)(.*)\z/m)
      end

      # stdout_file? and output_file?: a word matching +pattern+ (its
      # captures: the operator, an &, the target) that writes a file.
      def redirects_to_file?(words, pattern)
        words.each_with_index do |word, i|
          match = word.match(pattern)
          next unless match

          amp = match[2]
          target = match[3]
          target = words[i + 1] if target.empty? # "> file", ">& 2"
          return true if target.nil? # a dangling > or >&
          next if target == "/dev/null"
          next if !amp.empty? && target.match?(FD_TARGET)

          return true
        end
        false
      end

      # Whether a tee command writes a file of its own (an argument that
      # isn't an option, a redirection, a heredoc, a body or /dev/null).
      def tee_file?(words)
        verb = command_index(words)
        return false unless verb

        each_argument_index(words, verb + 1).any? { |i| filename_word?(words[i]) }
      end

      # Whether a tee argument names a file: not an option, a heredoc's tag,
      # a body word (HEREDOC, SUBST, a script) or /dev/null.
      def filename_word?(word)
        !word.start_with?("-", "<<") && !word.include?("\0") && !word.include?("\n") && word != "/dev/null"
      end

      # Whether a simple command reads its stdin as a text file it never
      # runs: cat or tee, git commit/tag -F - (--file -), gh pr|issue … -F -
      # (--body-file -) or gh release … -F - (--notes-file -).
      def data_reader?(words)
        args = arguments(words)
        verb = File.basename(args.first.to_s)
        return true if SINKS.include?(verb)

        case verb
        when "git" then git_reader?(args)
        when "gh" then gh_reader?(args)
        else false
        end
      end

      # Whether word +index+ of a simple command is the value of a message
      # option of a data reader: git commit/tag -m/--message, gh pr|issue …
      # -b/--body/-t/--title, gh release … -n/--notes/-t/--title. A
      # "$(cat <<'EOF' … EOF)" there is a message, not code.
      def message_arg?(words, index)
        return false unless index.positive?

        option = words[index - 1]
        args = arguments(words)
        case File.basename(args.first.to_s)
        when "git" then git_message_option?(args, option)
        when "gh" then gh_message_option?(args, option)
        else false
        end
      end

      # A simple command's arguments: the NAME= words, the redirections (with
      # their spaced targets), the <<TAG words and the heredoc bodies left
      # out.
      def arguments(words)
        each_argument_index(words).map { |i| words[i] }.reject { |word| assignment?(word) || heredoc_word?(word) }
      end

      # Whether a word is a heredoc's <<TAG or one of its bodies.
      def heredoc_word?(word)
        word.match?(REDIRECT) || word.include?("\0") || word.include?("\n")
      end

      # The words after git's global options ([-C dir …] commit), nil when
      # they run out.
      def git_arguments(args)
        i = 1
        i += GIT_OPTIONS_WITH_VALUE.include?(args[i]) ? 2 : 1 while i < args.size && args[i].start_with?("-")
        args[i..]
      end

      def git_reader?(args)
        rest = git_arguments(args)
        return false unless rest

        subcommand, *opts = rest
        return false unless %w[commit tag].include?(subcommand)

        stdin_file?(opts, "-F", "--file")
      end

      def gh_reader?(args)
        case args[1]
        when "pr", "issue"
          %w[create comment edit review].include?(args[2]) && stdin_file?(args.drop(3), "-F", "--body-file")
        when "release"
          %w[create edit].include?(args[2]) && stdin_file?(args.drop(3), "-F", "--notes-file")
        else
          false
        end
      end

      # Whether +opts+ take their text from stdin: "-F -", "--file -",
      # "-F-" or "--file=-".
      def stdin_file?(opts, short, long)
        opts.each_cons(2).any? { |a, b| [short, long].include?(a) && b == "-" } ||
          opts.include?("#{short}-") || opts.include?("#{long}=-")
      end

      def git_message_option?(args, option)
        rest = git_arguments(args)
        rest && %w[commit tag].include?(rest.first) && %w[-m --message].include?(option)
      end

      def gh_message_option?(args, option)
        case args[1]
        when "pr", "issue"
          %w[create comment edit review].include?(args[2]) && %w[-b --body -t --title].include?(option)
        when "release"
          %w[create edit].include?(args[2]) && %w[-n --notes -t --title].include?(option)
        else
          false
        end
      end
    end
  end
end
