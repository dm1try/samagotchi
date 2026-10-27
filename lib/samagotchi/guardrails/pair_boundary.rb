# frozen_string_literal: true

require_relative "review_paths"
require_relative "shell_paths"
require_relative "shell_lex"
require_relative "pair_command"
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
      GIT_CONFIG = "a participant's turn can't change git's global config or set what makes git run a command " \
                   "(core.hooksPath, core.fsmonitor, core.sshCommand, core.pager, core.editor, ! aliases)"
      UNREADABLE = "a participant's turn runs only commands chi can read: split this command, or write the file " \
                   "with the write tool"
      # A pair turn's execute runs without the environment variables whose
      # names say they hold a secret (Tools::Builtins, PairBoundary.scrubbed_env).
      SECRET_ENV_NAME = /KEY|TOKEN|SECRET|PASS|CREDENTIAL|AUTH/i

      # The unsets a pair turn's execute adds to its environment: every
      # variable of +env+ whose name SECRET_ENV_NAME matches.
      # @return [Hash{String => nil}]
      def self.scrubbed_env(env = ENV) = env.keys.grep(SECRET_ENV_NAME).to_h { |name| [name, nil] }

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
      # @param tmp_roots [#call] → Array<String>: where a write neither asks
      #   nor is denied (PairCommand.tmp_roots)
      def initialize(author:, root: -> {}, denied_dirs: -> { ReviewPaths.chi_dirs }, home: -> { Dir.home },
                     tmp_roots: -> { PairCommand.tmp_roots })
        @author = author
        @root = root
        @tmp_roots = tmp_roots
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

        paths = denylist
        return SECRET if paths.secret_refusal(targets.paths.compact)
        return command(targets, paths).refusal if targets.command

        nil
      end

      # A write or edit whose path is outside the project root (as given or
      # as it resolves), or a command that writes there (PairCommand); the
      # tmp dirs aside.
      def outside_write?(verdict)
        targets = verdict.targets
        return false unless targets
        return command(targets, nil).outside_writes? if targets.command
        return false unless WRITE_TOOLS.include?(verdict.call&.dig(:name).to_s)

        paths = targets.paths.to_a.compact
        root = @root.call.to_s
        paths.any? do |path|
          real = ProtectedPaths.real(path)
          next false if @tmp_roots.call.any? { |tmp| ShellPaths.within?(real, tmp) }

          root.empty? || !ShellPaths.within?(real, ProtectedPaths.real(root))
        end
      end

      def command(targets, paths)
        @command = nil unless @command&.first == targets
        @command ||= [targets, PairCommand.new(targets.command, cwd: targets.cwd, home: home, root: @root.call,
                                                                paths: paths || denylist, tmp_roots: @tmp_roots.call)]
        @command.last
      end

      def denylist = ReviewPaths.new(root: nil, denied_dirs: @denied_dirs.call, home: @home.call)

      def home = @home.call.to_s
    end
  end
end
