# frozen_string_literal: true

require_relative "path_resolve"

module Samagotchi
  module Guardrails
    # Core checks on what a call writes (Targets#writes?: write, edit,
    # memory_write, and a plugin tool whose targets: say writes: true),
    # after the hooks and before the rules. Paths are compared with
    # symlinks resolved (on the longest existing parent, `..` taken
    # physically, a dangling symlink followed: PathResolve.reals, the
    # lexical answer and where the write lands, a vote when either is
    # protected).
    #   deny: the approval store's dir, installed bundles (.bundles/:
    #         hooks, rules, manifests), attached context (a source's
    #         command runs later, outside the gate; chi context writes
    #         it), the peer mailbox (a message there speaks as a peer
    #         agent; chi peer writes it), System 1's saved runs (a
    #         label there may train a model) and schedules.json (a
    #         schedule's prompt and condition run unattended; chi schedule
    #         writes it); nothing legitimate writes there through a tool
    #         that says it writes.
    #   ask (once / session): config.yml, home.json (the chi home: the
    #         Ruby every chi launch boots), the chi shim (ChiShim: the
    #         `chi` every tool runs) and the plain hooks dir. The
    #         system bundle's config protocol edits config.yml with
    #         write/edit, so this keeps the user in the loop without
    #         breaking it.
    # execute can still write all of them (the guardrails bundle adds a
    # text match for that).
    #
    # A bundle's secrets (<state dir>/plugins/<bundle>/secrets, ctx.secrets)
    # are kept from chi's model whatever the call does: every file tool's
    # path there is denied, read included, and a shell command that names
    # the folder asks once (the user only). An accident guard, not a
    # sandbox: a command that doesn't name it (cd there first, a variable,
    # a script) still reads it.
    class ProtectedPaths
      SOURCE = "core"
      SECRETS_RULE = "bundle-secrets"
      SECRETS_SHELL_RULE = "bundle-secrets-shell"
      SECRETS_REASON = "a bundle's secrets (tokens) are its own: chi's model doesn't read or change them"
      SECRETS_SHELL_REASON = "the command names a bundle's secrets folder (its tokens)"
      # A command naming a secrets folder under chi's state dir, as typed:
      # the dir's name (samagotchi), then plugins/<bundle or a glob>/secrets.
      SECRETS_TEXT = %r{samagotchi/plugins/[^/\s'"]+/secrets(?![\w.-])}

      # @param store_dir [String] <state dir>/guardrails
      # @param bundles_dir [String] <memories>/.bundles
      # @param config_path [String] config.yml
      # @param hooks_dir [String] the plain hooks dir
      # @param context_dir [String, nil] <state dir>/context (ContextSources.root)
      # @param mailbox_dir [String, nil] <state dir>/mailbox (PeerMailbox.root)
      # @param runs_dir [String, nil] <state dir>/system_one (SystemOne::Runs)
      # @param home_path [String, nil] home.json (ChiHome.path)
      # @param shim_path [String, nil] the chi shim (ChiShim.path)
      # @param plugins_dir [String, nil] <state dir>/plugins (the bundles' data, their secrets/ in it)
      # @param schedules_path [String, nil] <state dir>/schedules.json (ChiDirs.schedules_file)
      def initialize(store_dir:, bundles_dir:, config_path:, hooks_dir:, context_dir: nil, runs_dir: nil, home_path: nil, shim_path: nil,
                     plugins_dir: nil, mailbox_dir: nil, schedules_path: nil)
        @plugins_dir = plugins_dir
        # The same, spelled out: this state dir's own plugins/<x>/secrets.
        @secrets_text = plugins_dir && Regexp.union(SECRETS_TEXT, *([plugins_dir.to_s.chomp("/")] | PathResolve.reals(plugins_dir.to_s.chomp("/"))).map do |dir|
          %r{#{Regexp.escape(dir)}/[^/\s'"]+/secrets(?![\w.-])}
        end)
        @deny = [
          ["guardrail-store", store_dir, "the approval store belongs to the user"],
          ["installed-bundles", bundles_dir, "installed bundles (hooks, rules, manifests) are changed by chi bundle install"],
          ["chi-context", context_dir, "attached context sources run commands; change them with chi context"],
          ["chi-mailbox", mailbox_dir, "a message there speaks as a peer agent; chi peer writes the peer mailbox"],
          ["system-one-runs", runs_dir, "System 1's saved runs are chi's own record"],
          ["chi-schedules", schedules_path, "schedules run commands and prompts unattended; change them with chi schedule"]
        ]
        @ask = [
          ["chi-config", config_path, "changes chi's config.yml"],
          ["chi-home", home_path, "changes the Ruby every chi launch boots"],
          ["chi-shim", shim_path, "changes the chi every tool's chi runs"],
          ["chi-hooks", hooks_dir, "changes chi's hooks"]
        ].select { |_, root, _| root }
      end

      # Vote on +verdict+ (its targets): a call whose targets say it writes
      # (Targets#writes?: write, edit, memory_write, or a plugin tool's
      # targets: writes: true) is judged on its paths.
      def check(verdict)
        targets = verdict.targets
        return verdict unless targets

        check_secrets(verdict, targets)
        return verdict unless targets.writes?

        paths = targets.paths.flat_map { |p| PathResolve.reals(p) }
        @deny.each do |rule, root, reason|
          next unless paths.any? { |p| PathResolve.within?(p, root) }

          verdict.deny!(reason, rule: rule, source: SOURCE, decided_by: "core")
        end
        @ask.each do |rule, root, reason|
          next unless paths.any? { |p| PathResolve.within?(p, root) }

          verdict.ask!(reason, scopes: %w[once session], rule: rule, source: SOURCE, decided_by: "core")
        end
        verdict
      end

      # Whether +path+ (absolute, resolved) is a bundle's secrets folder or
      # in it: <plugins dir>/<bundle>/secrets[/…].
      def secrets_path?(path)
        return false unless @plugins_dir

        PathResolve.reals(@plugins_dir.to_s.chomp("/")).any? do |dir|
          PathResolve.under?(path, dir) && path[(dir.length + 1)..].to_s.split("/")[1]&.casecmp?("secrets")
        end
      end

      # The path primitives (PathResolve) as this class has long named
      # them; specs and older callers reach them here.
      def self.expand(path, base = nil) = PathResolve.expand(path, base)
      def self.real(path) = PathResolve.real(path)
      def self.lexical_real(path) = PathResolve.lexical_real(path)
      def self.reals(path) = PathResolve.reals(path)
      def self.within?(path, root) = PathResolve.within?(path, root)
      def self.under?(path, dir) = PathResolve.under?(path, dir)
      def self.folds_case?(path) = PathResolve.folds_case?(path)

      private

      def check_secrets(verdict, targets)
        return unless @plugins_dir

        paths = targets.paths.flat_map { |p| PathResolve.reals(p) }
        if targets.shell?
          return unless paths.any? { |p| secrets_path?(p) } || targets.command.to_s.match?(@secrets_text)

          verdict.ask!(SECRETS_SHELL_REASON, scopes: %w[once], rule: SECRETS_SHELL_RULE, source: SOURCE, decided_by: "core")
        elsif paths.any? { |p| secrets_path?(p) }
          verdict.deny!(SECRETS_REASON, rule: SECRETS_RULE, source: SOURCE, decided_by: "core")
        end
      end
    end
  end
end
