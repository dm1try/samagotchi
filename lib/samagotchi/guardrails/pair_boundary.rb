# frozen_string_literal: true

require_relative "review_paths"
require_relative "shell_paths"
require_relative "shell_lex"
require_relative "parent_approvals"
require_relative "../steer"

module Samagotchi
  module Guardrails
    # A participant's pair turn (ParticipantMode :pair, a working session):
    # it acts with the session's tools under the owner's guardrails, and
    # their asks go to the owner (GuardrailWiring#request_approval). This
    # check sits in ReviewBoundary's seat (GuardrailWiring#checks), on in
    # every guardrails mode and with guardrails.enabled: false, active only
    # while the running turn's author is a participant. An accident guard
    # for a trusted team, not containment. It denies, never asks (the
    # owner's approval would let the participant's text reach what only the
    # owner should), on:
    #   - secrets: ReviewPaths' denylist (chi's state and config dirs, the
    #     web token, grants and every participants.json among them; home
    #     secret dirs and files: keys, shell startup files, histories,
    #     credential files; project secret files) on every file tool's path,
    #     read or written (read, write, edit, a plugin's targets: paths), and
    #     on the paths a command names (execute, and any call whose targets
    #     carry a command: ShellPaths, with SECRET_TEXT for a word it can't
    #     resolve);
    #   - owner-voiced tools (OWNER_VOICED, and any delegate_* tool): what
    #     speaks or acts in the owner's name beyond this turn (a delegate, a
    #     reminder, a note to another session, a background task, a
    #     forgotten output, the session's loaded tools); and memory_write:
    #     a memory reaches the owner's later sessions;
    #   - ask_user_question: there is no one on the participant's side to
    #     answer it here; the model asks in its reply instead.
    # And it asks the owner, always (Verdict#fresh_ask: no stored approval
    # answers it, and the rules can't lower it), before a write or edit
    # outside the session's project root.
    # Everything else goes on to the owner's checks and rules as for the
    # owner's turns.
    class PairBoundary
      RULE = "pair-boundary"
      SOURCE = "core"
      OWNER_VOICED = %w[delegate register_reminder cancel_reminder send_note forget_outputs task_create task_stop
                        find_tools].freeze
      OWNER_VOICED_PREFIX = "delegate_"
      ASK_TOOL = "ask_user_question"
      WRITE_TOOLS = %w[write edit].freeze

      ADVICE = "This is a participant's turn: work with this session's other tools, and say in your reply what " \
               "only the owner can do."
      SECRET = "a participant's turn can't read or write secrets or chi's own files"
      OWNER_ONLY = "a participant's turn can't use %s: it acts in the owner's name beyond this turn"
      MEMORY_WRITE = "a participant's turn writes no memories: they reach the owner's later sessions; say in your " \
                     "reply what to remember"
      ASK = "a participant's turn can't ask the user: ask in your reply"
      OUTSIDE_WRITE = "a participant's turn writes outside the session's project"
      CHI = "a participant's turn can't run chi: its commands act in the owner's name (sessions, shares, answers)"
      BACKGROUND = "a participant's turn can't leave a command running in the background: it would outlive the turn"
      ENVIRONMENT = "a participant's turn can't read the environment or the keychain: they hold the owner's secrets"
      HOME_SWEEP = "a participant's turn can't search or copy a folder that holds secrets or chi's own files"

      # A command's program name: what runs it on another's behalf comes
      # first (env, exec, nohup, bundle exec, ruby -Ilib …), skipped to find it.
      WRAPPERS = %w[env exec command nohup time sudo nice xargs setsid timeout stdbuf caffeinate bundle ruby].freeze
      # chi's own invocations a pair turn may run: they print and exit.
      CHI_ALLOWED = [%w[--version], %w[--help]].freeze
      # A chi invocation inside a script body (sh -c '…', eval) or a $(…).
      CHI_TEXT = %r{(?:\A|[\s;&|(`'"])(?:[^\s;&|(`'"]*/)?chi(?=\s|\z|[;&|)`'"])}
      SHELLS = %w[sh bash zsh dash fish ksh eval].freeze
      # Programs that detach what they start.
      DETACHERS = %w[nohup setsid disown daemonize].freeze
      # Programs that print the environment or a keychain's secrets.
      ENV_READERS = %w[printenv security].freeze
      ENV_TEXT = %r{/proc/[^\s]*/environ}
      # Programs that read a folder's whole tree: given home (or any folder
      # above a denied one) they reach the secrets in it.
      SWEEPERS = %w[find tar cp rsync scp zip 7z cpio grep egrep fgrep rg ag ack fd].freeze
      GLOB = /[*?\[\]{}]/
      # How many matches of a glob are checked against the denylist.
      GLOB_LIMIT = 500

      # What a command word that can't be resolved to a path is matched
      # with: chi's own dirs (ParentApprovals::CHI_TEXT, the state dir,
      # the web's grants and token), the home secret dirs, and the secret
      # file names ReviewPaths::SECRET_FILE has.
      SECRET_TEXT = Regexp.union(
        ParentApprovals::CHI_TEXT,
        %r{\.local/state/samagotchi|web-grants|grants\.json|web-token},
        %r{(?:\A|[\s/'"=])\.(?:ssh|gnupg|aws|kube|docker)(?![\w.-])},
        %r{(?:\A|[\s/'"=])(?:\.env(?:\.[\w.-]*)?|[._]netrc|\.npmrc|\.pypirc|\.git-credentials)(?![\w-])},
        /\bid_(?:rsa|dsa|ecdsa|ed25519)\b|credentials|\.(?:pem|p12|pfx|tfstate)\b/
      )

      # @param author [#call] → String, nil: the running turn's author
      #   (GuardrailWiring#turn_author); the check is off unless it is a
      #   participant's (Steer.participant_author?)
      # @param denied_dirs [#call] → Array<String>: chi's own dirs
      # @param home [#call] → String, nil
      # @param root [#call] → String, nil: the session's project root (the
      #   work tree top of its folder); a write outside it asks the owner
      #   (none: every write asks)
      def initialize(author:, root: -> {}, denied_dirs: -> { ReviewPaths.chi_dirs }, home: -> { Dir.home })
        @author = author
        @root = root
        @denied_dirs = denied_dirs
        @home = home
      end

      # Vote on +verdict+ (its call and targets).
      def check(verdict)
        return verdict unless Steer.participant_author?(@author.call)

        if (reason = refusal(verdict))
          return verdict.deny!(reason, rule: RULE, source: SOURCE, decided_by: "core", advice: ADVICE)
        end

        if outside_write?(verdict)
          verdict.ask!(OUTSIDE_WRITE, scopes: %w[once], rule: RULE, source: SOURCE, decided_by: "core")
          verdict.fresh_ask = true
        end
        verdict
      end

      private

      def refusal(verdict)
        call = verdict.call || {}
        tool = call[:name].to_s
        return ASK if tool == ASK_TOOL
        return format(OWNER_ONLY, tool) if OWNER_VOICED.include?(tool) || tool.start_with?(OWNER_VOICED_PREFIX)
        return MEMORY_WRITE if tool == "memory_write"

        targets = verdict.targets
        return nil unless targets

        paths = ReviewPaths.new(root: nil, denied_dirs: @denied_dirs.call, home: @home.call)
        return SECRET if paths.secret_refusal(targets.paths.compact)
        return command_refusal(targets.command, targets.cwd, paths) if targets.command

        nil
      end

      # A write or edit whose path is outside the project root (as given or
      # as it resolves).
      def outside_write?(verdict)
        return false unless WRITE_TOOLS.include?(verdict.call&.dig(:name).to_s)

        paths = verdict.targets&.paths.to_a.compact
        root = @root.call.to_s
        return !paths.empty? if root.empty?

        real_root = ProtectedPaths.real(root)
        paths.any? { |path| !ShellPaths.within?(ProtectedPaths.real(path), real_root) }
      end

      # Why a command may not run in a pair turn, nil when it may: it runs
      # chi, detaches something, reads the environment, sweeps a folder that
      # holds secrets, or names a secret (a path it resolves to, a glob or a
      # $var whose fixed part leads into one, SECRET_TEXT for the rest).
      def command_refusal(command, cwd, paths)
        text = command.to_s
        tokens = ShellLex.lex(text)
        code = ShellLex.code_text(text)
        subst = tokens.any? { |_, value| value.include?(ShellLex::SUBST) }
        return CHI if subst && code.match?(CHI_TEXT)
        return BACKGROUND if tokens.any? { |type, value| type == :op && value == "&" }
        return ENVIRONMENT if text.match?(ENV_TEXT)
        return SECRET if subst && code.match?(SECRET_TEXT)

        walk = ShellPaths::Walk.new(cwd, home, ENV)
        ShellLex.simple_commands(tokens).each do |words|
          next walk.step(words) if words.is_a?(Symbol)

          reason = words_refusal(words) || paths_refusal(words, walk.step(words), paths, cwd)
          return reason if reason
        end
        nil
      rescue ArgumentError, EncodingError
        text.scrub.match?(SECRET_TEXT) || text.scrub.match?(CHI_TEXT) ? SECRET : nil
      end

      # A simple command's own refusal, by its program: chi, a detacher, an
      # environment reader.
      def words_refusal(words)
        at = program_at(words)
        program = at && File.basename(words[at])
        args = at ? words[(at + 1)..] : []
        return CHI if program == "chi" && !CHI_ALLOWED.include?(args)
        return CHI if script_body(words, at)&.match?(CHI_TEXT)

        upto = at ? words[0..at] : words
        return BACKGROUND if upto.any? { |word| DETACHERS.include?(File.basename(word)) } || detached_session?(program, args)
        return ENVIRONMENT if ENV_READERS.include?(program) || bare_env?(words)

        nil
      end

      # Where the program is in +words+: past assignments, wrappers and their
      # options (and an option's value: ruby -I lib, timeout 10).
      def program_at(words)
        at = 0
        at += 1 while at < words.size && skipped?(words, at)
        at < words.size ? at : nil
      end

      def skipped?(words, at)
        word = words[at]
        return true if word.match?(/\A[A-Za-z_]\w*=/) || word.start_with?("-") || word.match?(/\A\d+[smhd]?\z/)
        return true if WRAPPERS.include?(File.basename(word))
        return true if word == "exec" && words[at - 1] == "bundle"

        previous = at.positive? ? words[at - 1] : nil
        !previous.nil? && previous.match?(/\A-[IrCe]\z/)
      end

      # The script a shell runs with -c (or eval's), nil for none.
      def script_body(words, at)
        return nil unless at && SHELLS.include?(File.basename(words[at]))
        return words[(at + 1)..].join(" ") if File.basename(words[at]) == "eval"

        flag = words.index("-c")
        flag && words[flag + 1]
      end

      # screen -d…, tmux new -d: a session left running.
      def detached_session?(program, args)
        (program == "screen" && args.any? { |arg| arg.match?(/\A-\w*d/) }) ||
          (program == "tmux" && args.any? { |arg| arg.match?(/\Anew(-session)?\z/) } && args.include?("-d"))
      end

      # env with no command after it prints the environment.
      def bare_env?(words)
        assignment = ->(word) { word.start_with?("-") || word.match?(/\A[A-Za-z_]\w*=/) }
        at = words.index { |word| !assignment.call(word) }
        return false unless at && File.basename(words[at]) == "env"

        words[(at + 1)..].all?(&assignment)
      end

      # The secrets a simple command's words reach: a resolved path on the
      # denylist; a glob that matches one or whose fixed part leads into a
      # denied dir; a $var word whose fixed part does; a sweeper given a
      # folder above a denied one; SECRET_TEXT for a word it can't read.
      def paths_refusal(words, resolved, paths, cwd)
        program_word = (at = program_at(words)) && File.basename(words[at])
        resolved.each do |word, path|
          if path
            return SECRET if paths.secret_refusal([path])
            return HOME_SWEEP if SWEEPERS.include?(program_word) && above_denied?(path, paths)
          elsif unresolved_secret?(word, paths, cwd) || word.match?(SECRET_TEXT)
            return SECRET
          end
        end
        nil
      end

      # A word Walk can't resolve: a glob checked by what it matches and by
      # its fixed part, a $var by its fixed part (the text before the first
      # glob character or $, with ~ and $HOME expanded). A script body
      # (spaces, quotes) is left to SECRET_TEXT.
      def unresolved_secret?(word, paths, cwd)
        return false if word.include?(ShellLex::SUBST) || word.match?(ShellPaths::SCRIPT)

        expanded = word.sub(%r{\A~(?=/|\z)}, home).sub(/\A\$(?:\{HOME\}|HOME\b)/, home)
        fixed = expanded[/\A[^*?\[\]{}$]*/]
        dir = cwd || Dir.pwd
        if !expanded.include?("$") && expanded.match?(GLOB)
          matches = Dir.glob(File.expand_path(expanded, dir)).first(GLOB_LIMIT)
          return true unless paths.secret_refusal(matches).nil?
        end
        return false if fixed.empty?

        leads_into_denied?(File.expand_path(fixed, dir), paths)
      end

      # Whether a path's text is the start of a denied root's (its parent,
      # or part of its name: ~/.ss) or inside one.
      def leads_into_denied?(prefix, paths)
        paths.denied_roots.any? { |root| root.start_with?(prefix) || ShellPaths.within?(prefix, root) }
      end

      # Whether +path+ is a denied root's folder or one above it (home,
      # ~/.config, ~/.local …).
      def above_denied?(path, paths)
        real = ProtectedPaths.real(path)
        paths.denied_roots.any? { |root| ShellPaths.within?(root, real) }
      end

      def home = @home.call.to_s
    end
  end
end
