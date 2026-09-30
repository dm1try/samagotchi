# frozen_string_literal: true

require "digest"
require "yaml"

require_relative "config"
require_relative "log"
require_relative "guardrails"
require_relative "hooks"
require_relative "edit_preview"
require_relative "tool_activity"

module Samagotchi
  # An Engine's tool guardrails: who can approve (the interface), the YAML
  # rules (config.yml's and installed bundles', reloaded on a file change),
  # the load failures, the protected paths, the approvals store, the context
  # a tool call is judged in, the approval question, and the Gate the kernel
  # asks before every tool call.
  #
  # What it needs from the Engine comes through lookups, read at call time.
  class GuardrailWiring
    # @return [Guardrails::LoadFailures] what failed to load (hooks, rules)
    attr_reader :failures

    # @return [Guardrails::Approvals]
    attr_reader :approvals

    # @param scratch   [Boolean] a `chi scratch` session (writes into the memories are denied)
    # @param hooks     [#call] → Hooks::Registry
    # @param tools     [#call] → Tools::Registry
    # @param session   [#call] → Session, nil
    # @param model_key [#call] → String, the effective model's overlay key
    # @param cancelled [#call] → Boolean, whether the running turn is cancelled
    # @param ask       [#call] (fields) → the answer; the Engine's question flow
    def initialize(scratch:, hooks:, tools:, session:, model_key:, cancelled:, ask:)
      @scratch = scratch
      @hooks_lookup = hooks
      @tools_lookup = tools
      @session_lookup = session
      @model_key_lookup = model_key
      @cancelled_lookup = cancelled
      @ask = ask
      @failures = Guardrails::LoadFailures.new
      @rules_mutex = Mutex.new
      @git = Guardrails::GitInfo.new
    end

    # Who can answer an approval: :repl, :worker or :non_interactive (the
    # default, so a bare Engine denies instead of waiting for nobody). Set
    # by the host (TerminalUI, Worker).
    def interface
      @interface || :non_interactive
    end

    def interface=(value)
      value = value.to_sym
      raise ArgumentError, "unknown interface #{value}" unless Guardrails::Context::INTERFACES.include?(value)

      @interface = value
    end

    # Where the approval store lives: beside Session's state dir
    # ($XDG_STATE_HOME/samagotchi/guardrails/).
    def state_dir=(state_dir)
      @approvals = Guardrails::Approvals.new(dir: Guardrails::Approvals.dir_for(state_dir))
      @protected = nil
    end

    # A turn starts: its origin, and the git facts read afresh.
    def begin_turn(origin)
      @origin = origin
      @git = Guardrails::GitInfo.new
    end

    # The gate every tool call asks first.
    # @return [Guardrails::Gate]
    def gate
      Guardrails::Gate.new(
        -> { @hooks_lookup.call },
        context_lookup: -> { context },
        model_key_lookup: -> { @model_key_lookup.call },
        approver: ->(verdict) { request_approval(verdict) },
        approvals_lookup: -> { @approvals },
        checks_lookup: -> { checks },
        cancelled_lookup: -> { @cancelled_lookup.call },
        tools_lookup: -> { @tools_lookup.call }
      )
    end

    # The gate's core checks, in order.
    def checks
      rules = self.rules
      [@failures, rules.hook_asks, protected_paths, (@scratch_writes ||= Guardrails::ScratchWrites.new if @scratch),
       rules].compact
    end

    # The YAML rules: config.yml's `guardrails:` section (rules, disable) and
    # installed bundles'. One that doesn't parse is a required load failure
    # (every call is denied). Read again when one of those files changed
    # (a stat of each per tool call), so a long-lived worker follows edits.
    # @return [Guardrails::Rules]
    def rules
      @rules_mutex.synchronize do
        stamp = rules_stamp
        if @rules.nil? || stamp != @rules_stamp
          @failures.drop(:rules)
          @rules = load_rules
          @rules_stamp = stamp
        end
        @rules
      end
    end

    # Installed bundles' guardrails/*.yml, by bundle name then file name.
    # A file that is missing, changed since install (sha256) or doesn't
    # parse is a required load failure.
    def bundle_rules
      require_relative "memory_bundle/provenance"
      rules = []
      MemoryBundle::Provenance.each_installed_with_guardrails do |bundle_name, data|
        if data[:error]
          Log.warn(:guardrails, "bundle_rules_invalid", echo: "[samagotchi:guardrails] bundle #{bundle_name}: #{data[:error]}", bundle: bundle_name)
          @failures.add("rules (bundle #{bundle_name})", data[:error], required: true, group: :rules)
          next
        end
        dir = MemoryBundle::Provenance.new(name: bundle_name).guardrails_dir
        data[:guardrails].sort_by { |k, _| k.to_s }.each do |basename, meta|
          what = "rules #{basename} (bundle #{bundle_name})"
          path = File.join(dir, basename.to_s)
          begin
            raise Guardrails::Rules::ParseError, "the file is missing" unless File.file?(path)

            expected = (meta.is_a?(Hash) ? meta[:sha256] : nil).to_s.sub(/\Asha256:/, "")
            actual = Digest::SHA256.hexdigest(File.binread(path))
            if expected != actual
              raise Guardrails::Rules::ParseError, "its sha256 differs from the installed one (edited after install? reinstall the bundle)"
            end

            doc = YAML.safe_load(File.read(path))
            raise Guardrails::Rules::ParseError, "expected a mapping with rules:" unless doc.is_a?(Hash)

            rules.concat(Guardrails::Rules.parse(doc["rules"], source: "bundle #{bundle_name}"))
          rescue Guardrails::Rules::ParseError, Psych::Exception => e
            Log.warn(:guardrails, "rules_file_invalid", echo: "[samagotchi:guardrails] #{what}: #{e.message}", bundle: bundle_name, file: basename.to_s)
            @failures.add(what, e.message, required: true, group: :rules)
          end
        end
      end
      rules
    rescue StandardError => e
      Log.error(:guardrails, "bundle_rules_failed", echo: "[samagotchi:guardrails] failed to read installed bundles' rules: #{e.class}: #{e.message}", error: e.class.name)
      @failures.add("bundle rules", "#{e.class}: #{e.message}", required: true, group: :rules)
      rules || []
    end

    def protected_paths
      @protected ||= begin
        require_relative "memory_bundle/provenance"
        config = Samagotchi::ConfigFile.read_yaml(path: Samagotchi::ConfigFile.global_path)
        hooks_dir = config.is_a?(Hash) && config["hooks"].is_a?(Hash) ? config["hooks"]["hooks_dir"] : nil
        Guardrails::ProtectedPaths.new(
          store_dir: File.dirname(@approvals.path),
          bundles_dir: MemoryBundle::Provenance.bundles_dir,
          config_path: Samagotchi::ConfigFile.global_path,
          hooks_dir: Hooks::Loader.expand_path(hooks_dir || Hooks::Loader.default_hooks_dir)
        )
      end
    end

    # The context the gate sees for a tool call now.
    # @return [Guardrails::Context]
    def context
      Guardrails::Context.new(cwd: Dir.pwd, session_id: @session_lookup.call&.id, interface: interface,
                              origin: @origin, git: @git)
    end

    # Ask the user to approve a call the gate voted `ask` on, through the
    # question flow (REPL sync handler, attached TUI, web). Settles the
    # verdict: allow with the picked scope, or deny with a note for the
    # model. A --non-interactive run has no one to ask and denies at once.
    # @param verdict [Guardrails::Verdict]
    # @return [Guardrails::Verdict]
    def request_approval(verdict)
      if interface == :non_interactive
        return verdict.settle!(:deny, decided_by: "no one", note: "No one to approve it (non-interactive run).")
      end

      # A plugin tool is asked about by its label, as its row shows it.
      label = ToolActivity.plugin_label(verdict.call[:name].to_s, registry: @tools_lookup.call)
      # verdict.call is the call that will run (a hook may have replaced it).
      payload = Guardrails::Approval.payload(verdict, label: label, preview: approval_preview(verdict.call))
      Guardrails::Approval.settle(verdict, @ask.call(payload), payload[:approval][:scopes])
    end

    private

    # [path, mtime, size] of config.yml and every installed bundle's
    # manifest.json and guardrails/ file.
    def rules_stamp
      require_relative "memory_bundle/provenance"
      paths = [Samagotchi::ConfigFile.global_path] +
              Dir[File.join(MemoryBundle::Provenance.bundles_dir, "*", "{manifest.json,guardrails/*}")]
      paths.compact.sort.map do |path|
        stat = File.stat(path)
        [path, stat.mtime.to_r, stat.size]
      rescue SystemCallError
        [path]
      end
    end

    def load_rules
      section = Samagotchi::ConfigFile.read_yaml(path: Samagotchi::ConfigFile.global_path)
      section = section["guardrails"] if section.is_a?(Hash)
      rules = []
      disable = []
      begin
        raise Guardrails::Rules::ParseError, "guardrails must be a mapping" unless section.nil? || section.is_a?(Hash)

        rules = Guardrails::Rules.parse(section && section["rules"], source: "config")
        disable = Guardrails::Rules.parse_disable(section && section["disable"])
      rescue Guardrails::Rules::ParseError => e
        Log.warn(:guardrails, "config_rules_invalid", echo: "[samagotchi:guardrails] config.yml guardrails rules: #{e.message}")
        @failures.add("rules in config.yml", e.message, required: true, group: :rules)
      end
      Guardrails::Rules.new(rules + bundle_rules, disable: disable,
                            enabled: Samagotchi::Config.get("guardrails.enabled") != false)
    end

    # The dry-run diff of an edit/write call for its approval; a preview
    # that fails only leaves the diff out, it never denies the call.
    def approval_preview(call)
      EditPreview.for(call)
    rescue StandardError => e
      Log.warn(:guardrails, "edit_preview_failed", error: "#{e.class}: #{e.message}")
      nil
    end
  end
end
