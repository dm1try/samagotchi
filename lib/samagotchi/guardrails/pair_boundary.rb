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
    #     on what a command does (execute, and any call whose targets carry
    #     a command: PairCommand, which also refuses chi and chi web on a
    #     loopback name, URL openers (open, xdg-open, a browser) and
    #     listeners (nc -l, socat …LISTEN, a static HTTP server), background
    #     and scheduled jobs, the environment and
    #     credential printers, git config writes (reads only), home sweeps
    #     and links to them, and a program named by a $var or a glob); a
    #     write or edit of git's hooks (GIT_HOOKS);
    #   - owner-voiced tools (OWNER_VOICED, and any delegate_* tool): what
    #     speaks or acts in the owner's name beyond this turn (a delegate, a
    #     reminder, a note to another session, a background task, a
    #     forgotten output, the session's loaded tools); the tools that read
    #     the owner's background tasks (OWNER_TASK_READERS); and memory_write:
    #     a memory reaches the owner's later sessions;
    #   - ask_user_question: there is no one on the participant's side to
    #     answer it here; the model asks in its reply instead.
    # And it asks the owner, always (Verdict#fresh_ask: no stored approval
    # answers it, and the rules can't lower it), before a write or an edit
    # that may land outside the session's project root, or a command that
    # may write there (failing closed: PairCommand#outside_writes?); a tmp
    # dir the project isn't in aside (PairCommand.writable?). No project
    # (the home folder or above it): every write asks.
    # Everything else goes on to the owner's checks and rules as for the
    # owner's turns.
    class PairBoundary
      RULE = "pair-boundary"
      SOURCE = "core"
      OWNER_VOICED = %w[delegate register_reminder cancel_reminder send_note forget_outputs task_create task_stop
                        find_tools].freeze
      OWNER_VOICED_PREFIX = "delegate_"
      # The background task tools that read the owner's tasks (a pair turn
      # starts none: task_create is owner-voiced, and its execute is never
      # handed over).
      OWNER_TASK_READERS = %w[task_wait task_get task_list].freeze
      ASK_TOOL = "ask_user_question"
      WRITE_TOOLS = %w[write edit].freeze

      ADVICE = "This is a participant's turn: work with this session's other tools, and say in your reply what " \
               "only the owner can do."
      SECRET = "a participant's turn can't read or write secrets or chi's own files"
      OWNER_ONLY = "a participant's turn can't use %s: it acts in the owner's name beyond this turn"
      OWNER_TASKS = "a participant's turn can't use %s: the background tasks are the owner's, and their output with them"
      MEMORY_WRITE = "a participant's turn writes no memories: they reach the owner's later sessions; say in your " \
                     "reply what to remember"
      ASK = "a participant's turn can't ask the user: ask in your reply"
      OUTSIDE_WRITE = "a participant's turn writes outside the session's project"
      NO_PROJECT = "a participant's turn writes, and this session's folder is the home folder or above it (or none): " \
                   "there is no project to keep it in"
      CHI = "a participant's turn can't run chi: its commands act in the owner's name (sessions, shares, answers)"
      BACKGROUND = "a participant's turn can't leave a command running in the background: it would outlive the turn"
      ENVIRONMENT = "a participant's turn can't read the environment or the keychain: they hold the owner's secrets"
      HOME_SWEEP = "a participant's turn can't search, copy or link a folder that holds secrets or chi's own files"
      LINK = "a participant's turn makes a link: a path through it can lead out of the project, so the owner " \
             "approves it"
      GIT_CONFIG = "a participant's turn writes no git config (git config but its reads, git -c, --config-env, a " \
                   "clone's or init's -c/--config, GIT_CONFIG_* and GIT_TEMPLATE_DIR): settings can make git run a " \
                   "command in the owner's name"
      ENV_LOADER = "a participant's turn runs mise or direnv: they load the project's env files (a mise.local.toml, " \
                   "an .envrc), which may hold the owner's secrets, so the owner approves it"
      MISE_CONFIG = "a participant's turn changes mise's config: the owner's next worker start runs it (its [env] " \
                    "can run commands), so the owner approves it"
      GIT_HOOKS = "a participant's turn can't write or install git's hooks (.git/hooks, .git/modules/*/hooks, a " \
                  "template, pre-commit install, husky): git runs them in the owner's name"
      # chi web on loopback asks the owner's token too (Web::App#token_gate,
      # LAN mode); this text check stays as defense in depth: a loopback-only
      # chi web still answers loopback as the owner.
      CHI_WEB = "a participant's turn can't call chi web on this machine: it is the owner's (sessions, shares, answers)"
      # A page opened in the owner's browser carries the owner's cookies
      # (chi web's on 127.0.0.1 or the LAN address among them) to whatever
      # it points at; a port listening here could catch them.
      OPENER = "a participant's turn can't open a URL or a file in the owner's apps: a browser sends that page the " \
               "owner's cookies"
      LISTENER = "a participant's turn can't listen on a port: what it serves on this machine could catch the " \
                 "owner's browser cookies"
      NET = "a participant's turn runs a command chi can't read for sure (git or chi behind a program it doesn't " \
            "know, or a $(…) kept in a value the shell expands later), so the owner approves it"
      VERB = "a participant's turn runs only a program named plainly: no $, $(…) or glob in a command's name"
      UNREADABLE = "a participant's turn runs only commands chi can read: split this command, or write the file " \
                   "with the write tool"
      # A pair turn's execute runs without the environment variables whose
      # names say they hold a secret (Tools::Builtins, PairBoundary.scrubbed_env).
      SECRET_ENV_NAME = /KEY|TOKEN|SECRET|PASS|CREDENTIAL|AUTH/i
      # chi web's port when config names none (Config's web.port default).
      DEFAULT_WEB_PORT = 4567

      # The ports chi web may answer on here: the one the running chi web
      # recorded (Web::Running), config's web.port, and the default. A
      # Bridge's port needs no entry: it answers only with its secret, in
      # the worker's bridge.json under chi's state dir (denied).
      # @return [Array<Integer>]
      def self.web_ports
        require_relative "../config"
        require_relative "../web/running"
        configured = Config.get("web.port").to_s.to_i
        [Web::Running.port, (configured if configured.positive?), DEFAULT_WEB_PORT].compact.uniq
      rescue StandardError, LoadError
        [DEFAULT_WEB_PORT]
      end

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
        %r{(?:\A|[\s/'"=])(?:\.env(?:\.[\w.-]*)?|\.envrc|\.?mise(?:\.[\w-]+)?\.local\.toml|(?:\.config/mise|\.?mise)/config(?:\.[\w-]+)?\.local\.toml|[._]netrc|\.npmrc|\.pypirc|
           \.git-credentials)(?![\w-])}x,
        /\bid_(?:rsa|dsa|ecdsa|ed25519)\b|credentials|\.(?:pem|p12|pfx|tfstate)\b/
      )

      # @param author [#call] → String, nil: the running turn's author
      #   (GuardrailWiring#turn_author); the check is off unless it is a
      #   participant's (Steer.participant_author?)
      # @param denied_dirs [#call] → Array<String>: chi's own dirs
      # @param home [#call] → String, nil
      # @param root [#call] → String, nil: the session's project root (the
      #   work tree top of its folder); a write outside it asks the owner
      #   (none, or the home folder or above it: every write asks)
      # @param web_ports [#call] → Array<Integer>: chi web's ports here
      #   (.web_ports); a command naming one on a loopback name is denied
      def initialize(author:, root: -> {}, denied_dirs: -> { ReviewPaths.chi_dirs }, home: -> { Dir.home },
                     web_ports: -> { PairBoundary.web_ports })
        @web_ports = web_ports
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

        if (reason = ask_reason(verdict))
          verdict.ask!(reason, scopes: %w[once], rule: RULE, source: SOURCE, decided_by: "core")
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
        return format(OWNER_TASKS, tool) if OWNER_TASK_READERS.include?(tool)
        return MEMORY_WRITE if tool == "memory_write"

        targets = verdict.targets
        return nil unless targets

        paths = denylist
        return SECRET if paths.secret_refusal(targets.paths.compact)
        return GIT_HOOKS if WRITE_TOOLS.include?(tool) && targets.paths.compact.any? { |path| PairCommand.git_hook?(path) }
        return command(targets, paths).refusal if targets.command

        nil
      end

      # Why the owner is asked (fresh, once): a command that makes a link
      # (LINK), one that runs mise or direnv (ENV_LOADER), a write to mise's
      # config (MISE_CONFIG), a command chi can't read for sure (NET:
      # PairCommand#net_ask?), a write that may land outside the project (OUTSIDE_WRITE, or
      # NO_PROJECT without one); nil when nothing asks.
      def ask_reason(verdict)
        targets = verdict.targets
        return LINK if targets&.command && command(targets, nil).links?
        return ENV_LOADER if targets&.command && command(targets, nil).loads_env?
        return MISE_CONFIG if mise_config_write?(verdict)
        return NET if targets&.command && command(targets, nil).net_ask?
        return nil unless outside_write?(verdict)

        project_root ? OUTSIDE_WRITE : NO_PROJECT
      end

      # A write or edit of a mise config file (PairCommand.mise_config?), or a
      # command that writes or names one (PairCommand#mise_config_write?).
      def mise_config_write?(verdict)
        targets = verdict.targets
        return false unless targets
        return command(targets, nil).mise_config_write? if targets.command
        return false unless WRITE_TOOLS.include?(verdict.call&.dig(:name).to_s)

        targets.paths.to_a.compact.any? { |path| PairCommand.mise_config?(File.expand_path(path, targets.cwd || Dir.pwd)) }
      end

      # A write or edit whose path may land outside the project root, or a
      # command that may write there (PairCommand#outside_writes?); a tmp
      # dir the project isn't in aside (PairCommand.writable?).
      def outside_write?(verdict)
        targets = verdict.targets
        return false unless targets
        return command(targets, nil).outside_writes? if targets.command
        return false unless WRITE_TOOLS.include?(verdict.call&.dig(:name).to_s)

        targets.paths.to_a.compact.any? do |path|
          !PairCommand.writable?(File.expand_path(path), root: project_root, cwd: targets.cwd)
        end
      end

      def command(targets, paths)
        @command = nil unless @command&.first == targets
        @command ||= [targets, PairCommand.new(targets.command, cwd: targets.cwd, home: home, root: project_root,
                                                                paths: paths || denylist, web: web_text)]
        @command.last
      end

      # The session's project root; nil without one, or when it is the home
      # folder or above it (ReviewPaths.home_root?): then every write asks.
      def project_root
        root = @root.call.to_s
        root.empty? || ReviewPaths.home_root?(root, home) ? nil : root
      end

      def web_text = PairCommand.web_text(@web_ports.call, hostnames: PairCommand.hostnames)

      def denylist = ReviewPaths.new(root: nil, denied_dirs: @denied_dirs.call, home: @home.call)

      def home = @home.call.to_s
    end
  end
end
