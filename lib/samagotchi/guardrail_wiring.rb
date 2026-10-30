# frozen_string_literal: true

require "yaml"

require_relative "config"
require_relative "log"
require_relative "guardrails"
require_relative "guardrails/parent_approvals"
require_relative "guardrails/parent_policy"
require_relative "model_match"
require_relative "memory_bundle/manifest"
require_relative "version"
require_relative "hooks"
require_relative "edit_preview"
require_relative "system_one"
require_relative "tool_activity"
require_relative "turn_origin"
require_relative "participant_mode"

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
    # @param model_name [#call] → String, nil: the effective model's bare name
    # @param cancelled [#call] → Boolean, whether the running turn is cancelled
    # @param ask       [#call] (fields) → the answer; the Engine's question flow
    # @param notify    [#call] (message) → shows a guardrails line in every UI
    #   (a bundle's rules kept because it needs a newer chi)
    # @param system_one [#call] → SystemOne::Client or nil: the judgment client
    #   (nil while `guardrails.system_one.mode` is off or no host is set)
    # @param cancel_controller [#call] → the running turn's CancellationController, nil
    # @param participant [#call] (author) → the participant's
    #   Participants::Entry (participants.json: their name, their grant's
    #   mode), nil for none
    def initialize(scratch:, hooks:, tools:, session:, model_key:, cancelled:, ask:, model_name: -> {},
                   notify: ->(_message) {}, system_one: -> {}, cancel_controller: -> {}, participant: ->(_author) {})
      @scratch = scratch
      @hooks_lookup = hooks
      @tools_lookup = tools
      @session_lookup = session
      @model_key_lookup = model_key
      @model_name_lookup = model_name
      @cancelled_lookup = cancelled
      @ask = ask
      @notify = notify
      @system_one = system_one
      @cancel_controller = cancel_controller
      @participant = participant
      @turn_mode = nil
      # Bundle name → the rules last loaded from it whole, kept while the
      # installed version needs a newer chi; [name, version] said so once.
      @loaded_bundle_rules = {}
      @kept_noticed = {}
      @failures = Guardrails::LoadFailures.new
      @rules_mutex = Mutex.new
      @git = Guardrails::GitInfo.new
      @origin = TurnOrigin::NONE
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

    # The approval scopes a scratch session offers: nothing outlives it.
    SCRATCH_SCOPES = %w[once session].freeze

    # Where the approval store lives: beside Session's state dir
    # ($XDG_STATE_HOME/samagotchi/guardrails/). A scratch session reads
    # it but keeps its own session approvals in memory.
    def state_dir=(state_dir)
      @approvals = Guardrails::Approvals.new(dir: Guardrails::Approvals.dir_for(state_dir))
      @approvals = Guardrails::Approvals::InMemory.new(@approvals) if @scratch
      @system_one_log = nil
      @protected = nil
    end

    # A turn starts: its origin (Engine#run_turn's TurnOrigin; nil or a
    # Hash is read as one, TurnOrigin.of), the git facts read afresh, and
    # a participant's turn's mode decided once for the whole turn
    # (#turn_mode).
    def begin_turn(origin)
      @origin = TurnOrigin.of(origin)
      @git = Guardrails::GitInfo.new
      author = turn_author
      @turn_entry = author && @participant.call(author)
      @turn_mode = author && participant_turn_mode(@session_lookup.call, @turn_entry)
    end

    # A participant's turn's mode: in a Verify fresh child the one saved
    # on it at spawn (VerifyFreshOrigin#turn_mode: :review unless saved
    # :pair), never looked up again; elsewhere ParticipantMode.for_turn.
    def participant_turn_mode(session, entry)
      fresh = session.respond_to?(:verify_fresh) && session.verify_fresh
      fresh ? fresh.turn_mode : ParticipantMode.for_turn(session, entry)
    end
    private :participant_turn_mode

    # The running participant turn's mode (ParticipantMode.for_turn: :pair
    # only in a working session for a participant invited to act), decided
    # at its start; nil for the owner's turns. The boundary in #checks, the
    # Engine's stamp and mid-turn stop, and ToolRunner read it.
    # @return [Symbol, nil]
    attr_reader :turn_mode

    # Who wrote the running turn when it isn't the session's owner (its
    # origin's participant author); nil for the owner's turns and every
    # other origin.
    # @return [String, nil]
    def turn_author = @origin.participant_author

    # The gate every tool call asks first.
    # @return [Guardrails::Gate]
    def gate
      Guardrails::Gate.new(
        -> { @hooks_lookup.call },
        context_lookup: -> { context },
        model_key_lookup: -> { @model_key_lookup.call },
        model_name_lookup: -> { @model_name_lookup.call },
        approver: ->(verdict) { request_approval(verdict) },
        approvals_lookup: -> { @approvals },
        checks_lookup: -> { checks },
        cancelled_lookup: -> { @cancelled_lookup.call },
        tools_lookup: -> { @tools_lookup.call }
      )
    end

    # The gate's core checks, in order. A delegate child's boundary comes
    # before the rules, so its ask keeps the child-boundary rule id (and
    # its once/session scopes) when a strict rule asks too. The
    # participant's boundary comes before both, by the session's
    # ParticipantMode: a review turn's (ReviewBoundary) or a pair turn's
    # (PairBoundary). Either denies what a participant's turn may not do,
    # never asks about it; both are no-ops for the owner's turns.
    def checks
      rules = self.rules
      [@failures, participant_boundary, rules.hook_asks, protected_paths,
       (@scratch_writes ||= Guardrails::ScratchWrites.new if @scratch), child_boundary, rules].compact
    end

    # The boundary for a participant's turn in this session (#checks).
    def participant_boundary
      @turn_mode == ParticipantMode::PAIR ? pair_boundary : review_boundary
    end

    # A participant's review turn's boundary (Guardrails::ReviewBoundary): a
    # no-op unless the running turn's author is a participant's.
    def review_boundary
      @review_boundary ||= Guardrails::ReviewBoundary.new(author: -> { turn_author }, root: -> { boundary_root })
    end

    # A participant's pair turn's boundary (Guardrails::PairBoundary): a
    # no-op unless the running turn's author is a participant's.
    def pair_boundary
      @pair_boundary ||= Guardrails::PairBoundary.new(author: -> { turn_author }, root: -> { boundary_root })
    end

    # The delegate child's boundary (Guardrails::ChildBoundary); nil for
    # any other session.
    def child_boundary
      return nil unless @session_lookup.call&.delegate?

      @child_boundary ||= Guardrails::ChildBoundary.new(
        root: -> { boundary_root },
        worktrees: -> { (root = boundary_root) ? @git.worktrees(root) : [] },
        common_dir: -> { (root = boundary_root) && @git.common_dir(root) },
        branch: -> { (root = boundary_root) && @git.branch(root) }
      )
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
    # parse is a required load failure. A bundle whose requires_chi this
    # chi doesn't meet isn't read (its rules may use keys this chi doesn't
    # know): the rules last loaded from it stay (#too_new_bundle_rules).
    def bundle_rules
      require_relative "memory_bundle/provenance"
      rules = []
      MemoryBundle::Provenance.each_installed(holding: :guardrails) do |bundle_name, bundle|
        if bundle.error?
          Log.warn(:guardrails, "bundle_rules_invalid", echo: "[samagotchi:guardrails] bundle #{bundle_name}: #{bundle.error}", bundle: bundle_name)
          @failures.add("rules (bundle #{bundle_name})", bundle.error, required: true, group: :rules)
          next
        end
        if (too_new = MemoryBundle::Manifest.requires_chi_failure(bundle.requires_chi, Samagotchi::VERSION))
          rules.concat(too_new_bundle_rules(bundle_name, bundle, too_new))
          next
        end
        dir = MemoryBundle::Provenance.new(name: bundle_name).guardrails_dir
        loaded = []
        whole = true
        bundle.guardrails.sort.each do |basename, sha|
          what = "rules #{basename} (bundle #{bundle_name})"
          path = File.join(dir, basename)
          begin
            raise Guardrails::Rules::ParseError, "the file is missing" unless File.file?(path)

            unless MemoryBundle::Provenance.sha_matches?(path, sha)
              raise Guardrails::Rules::ParseError, "its sha256 differs from the installed one (edited after install? reinstall the bundle)"
            end

            doc = YAML.safe_load_file(path)
            raise Guardrails::Rules::ParseError, "expected a mapping with rules:" unless doc.is_a?(Hash)

            loaded.concat(Guardrails::Rules.parse(doc["rules"], source: "bundle #{bundle_name}"))
          rescue Guardrails::Rules::ParseError, Psych::Exception => e
            Log.warn(:guardrails, "rules_file_invalid", echo: "[samagotchi:guardrails] #{what}: #{e.message}", bundle: bundle_name, file: basename.to_s)
            @failures.add(what, e.message, required: true, group: :rules)
            whole = false
          end
        end
        rules.concat(loaded)
        @loaded_bundle_rules[bundle_name] = loaded if whole
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
        require_relative "context_sources"
        require_relative "chi_home"
        Guardrails::ProtectedPaths.new(
          store_dir: File.dirname(@approvals.path),
          bundles_dir: MemoryBundle::Provenance.bundles_dir,
          config_path: Samagotchi::ConfigFile.global_path,
          hooks_dir: Hooks::Loader.hooks_dir,
          context_dir: ContextSources.root,
          home_path: ChiHome.path
        )
      end
    end

    # The context the gate sees for a tool call now.
    # @return [Guardrails::Context]
    def context
      Guardrails::Context.new(cwd: Dir.pwd, session_id: @session_lookup.call&.id, interface: interface,
                              origin: @origin.wire, git: @git)
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

      # A plugin tool is asked about by its targets:' label:, else its
      # label, as its row shows it; a call that acts as another tool (an MCP
      # tool behind call_tool) by that tool's label, else (none registered)
      # by its name (Approval.payload).
      acts_as = verdict.targets&.acts_as
      label = verdict.targets&.label ||
              ToolActivity.plugin_label(acts_as || verdict.call[:name].to_s, registry: @tools_lookup.call)
      # verdict.call is the call that will run (a hook may have replaced it).
      # A participant's turn's ask names them and offers once only
      # (Approval.payload's author:), whichever session it is.
      author = turn_author
      payload = Guardrails::Approval.payload(verdict, label: label, preview: approval_preview(verdict.call),
                                                      only: (SCRATCH_SCOPES if @scratch), author: author,
                                                      author_name: (@turn_entry&.name if author))
      # A call on chi's own config, hooks or guardrails is the user's to
      # allow, never a parent agent's (Guardrails::ParentPolicy).
      payload[:user_only] = Guardrails::ParentApprovals.protected_facts?(payload[:approval])
      # System 1: the ask is judged before the user sees it, and in `on` mode
      # one that passes every gate is allowed once without reaching them
      # (docs/guardrails.md, "System 1").
      judgment = begin
        system_one_judge(payload, targets: verdict.targets)
      rescue LLM::RequestCancelled
        return turn_stopped(verdict)
      end
      # A turn stopped while the judge was asked opens no card.
      return turn_stopped(verdict) if @cancelled_lookup.call

      if judgment && judgment[:auto]
        verdict.judgment = { id: judgment[:id], p: judgment[:p] }
        verdict.settle!(:allow, decided_by: "system one")
        verdict.scope = "once"
        return verdict
      end

      # The card and the session file carry the facts as the hash they were.
      answer = @ask.call(payload.merge(approval: payload[:approval].to_h))
      system_one_label(judgment, answer, payload)
      Guardrails::Approval.settle(verdict, answer, payload[:approval].scopes)
    end

    private

    # The deny for a call whose turn was stopped before its ask reached the
    # user (as Guardrails::Gate words one stopped before the vote).
    def turn_stopped(verdict)
      verdict.settle!(:deny, decided_by: "core", note: "The turn was stopped before the user was asked.")
    end

    # The judgments log (SystemOne::Log), beside the approvals store; nil
    # while there is no store dir.
    def system_one_log
      return nil if @approvals.nil?

      @system_one_log ||= SystemOne::Log.new(dir: File.dirname(@approvals.path))
    end

    # System 1's judgment of an ask, written to the log before the user is
    # asked, with the decision it led to: "auto" (it answered for the user),
    # "asked" (on mode, the user decides) or "audit" (audit mode). A
    # participant's turn (review or pair) is never judged, so never
    # auto-allowed: its asks go to the owner. No client (mode off, no
    # host) means no line at all. A judgment that fails is logged with p nil,
    # so the failures are in the log too.
    # @return [Hash, nil] {id:, p:, auto:}, nil when nothing was written
    def system_one_judge(payload, targets: nil)
      return nil if Steer.participant_author?(turn_author)

      client = @system_one.call
      log = system_one_log
      return nil if client.nil? || log.nil?

      approval = payload[:approval]
      # The judgments log is read once for this ask: the state's examples and
      # the record gate both use these entries. The judgment of the ask being
      # judged is written after it, so the examples are always earlier asks.
      entries = log.entries
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      answers = begin
        client.ask(state: SystemOne::ApprovalQuestion.state(approval, session_title: @session_lookup.call&.title,
                                                            entries: entries),
                   questions: { SystemOne::ApprovalQuestion::ID => SystemOne::ApprovalQuestion.question },
                   cancel_controller: @cancel_controller.call)
      rescue LLM::RequestCancelled
        raise
      rescue StandardError => e
        # The client already turns every failure it knows into a nil; this is
        # the unexpected one. Either way the ask goes to the user.
        Samagotchi::Log.warn(:guardrails, "system_one_ask_failed", error: "#{e.class}: #{e.message}")
        nil
      end
      latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      p = answers && answers[SystemOne::ApprovalQuestion::ID]&.noul
      auto = system_one_auto_allow?(client, approval, p, entries, targets: targets)
      decision = system_one_decision(client, auto)

      id = log.judgment(session_id: @session_lookup.call&.id,
                        rule: approval.rule, source: approval.source, tool: approval.tool,
                        **SystemOne::ApprovalQuestion.call_fields(approval),
                        repo_name: approval.repo_name,
                        p: p, threshold: Config.get("guardrails.system_one.threshold"), model: client.model,
                        latency_ms: latency_ms, decision: decision, origin: "live")
      # A judgment the log cannot hold is no judgment: the user is asked.
      { id: id, p: p, auto: auto && !id.nil? }
    rescue LLM::RequestCancelled
      raise
    rescue StandardError => e
      # The approval never fails because of System 1.
      Samagotchi::Log.warn(:guardrails, "system_one_judgment_failed", error: "#{e.class}: #{e.message}")
      nil
    end

    # What the judgment line says it did: "auto" (System 1 answered for the
    # user), "asked" (on mode, the user decides), "audit" (nothing decided).
    def system_one_decision(client, auto)
      return "auto" if auto

      client.mode == "on" ? "asked" : "audit"
    end

    # Every gate an auto-allow must pass, in order: the mode, the rule the
    # user opted in, the never-list and chi's own files, the probability, and
    # the rule's record. Any one that fails leaves the ask to the user. The
    # entries are the judgment log read once for this ask.
    # @param approval [Guardrails::ApprovalFacts] the ask's facts
    # @param entries [Array<Hash>] SystemOne::Log#entries
    # @param targets [Guardrails::Targets, nil] the call's, for its env:
    def system_one_auto_allow?(client, approval, p, entries, targets: nil)
      return false unless client.mode == "on"

      rule = approval.rule.to_s
      return false if rule.empty?
      return false unless system_one_rules.include?(rule)
      return false if SystemOne::SelfProtect.refuse?(approval, targets: targets)

      threshold = Config.get("guardrails.system_one.threshold").to_f
      return false if p.nil? || p.to_f < threshold

      min_record = Config.get("guardrails.system_one.min_record").to_i
      SystemOne::Record.new(entries, rule: rule).qualifies?(threshold: threshold, min_record: min_record)
    rescue StandardError => e
      Samagotchi::Log.warn(:guardrails, "system_one_gate_failed", error: "#{e.class}: #{e.message}")
      false
    end

    # guardrails.system_one.rules: a "|"-separated string or a YAML list,
    # read with the same grammar as guardrails.small_models.
    def system_one_rules
      ModelMatch.parse(Config.get("guardrails.system_one.rules"))
    rescue StandardError
      []
    end

    # The user's answer to that ask, as a label on the judgment: the scope
    # they took, a denial, or none for an ask that was cancelled. A parent
    # agent's answer is not the user's: its allow labels nothing, and its
    # deny is a label only where the parent could have allowed — a parent
    # that was not allowed to permit says nothing about what the user would
    # have done (docs/guardrails.md, "System 1").
    def system_one_label(judgment, answer, payload)
      id = judgment && judgment[:id]
      return nil if id.nil?

      scopes = Array(payload[:approval].scopes)
      if !answer.is_a?(Samagotchi::QuestionAnswer)
        label = "none"
      elsif answer.parent_agent?
        return nil if parent_allowed?(answer, scopes) || !parent_may_permit?(payload)

        label = "deny"
      else
        index = answer.selected_indices.first
        label = if index && index < scopes.size
                  scopes[index] == "once" ? "allow_once" : "allow_wide"
                else
                  "deny"
                end
      end
      system_one_log.label(id, label, question_id: (answer.id if answer.is_a?(Samagotchi::QuestionAnswer)))
    rescue StandardError => e
      Samagotchi::Log.warn(:guardrails, "system_one_label_failed", error: "#{e.class}: #{e.message}")
      nil
    end

    # Whether a parent's answer picked one of the offered scopes.
    def parent_allowed?(answer, scopes)
      index = answer.selected_indices.first
      !index.nil? && index < scopes.size
    end

    # Whether this session's parent level lets a parent allow a call at all,
    # and the ask is not one only the user may answer.
    def parent_may_permit?(payload)
      return false if payload[:user_only]

      Guardrails::ParentPolicy.for_session(@session_lookup.call).allow?("permit")
    end

    # The work tree top of the session's working_directory (the folder
    # itself outside a repo, or when it's gone); never Dir.pwd, which is
    # the waker's cwd for a worker whose folder is gone.
    def boundary_root
      dir = @session_lookup.call&.working_directory.to_s
      return nil if dir.empty?

      @git.root(dir) || File.expand_path(dir)
    end

    # The rules of a bundle that needs a newer chi: the ones last loaded
    # from it, with one notice per bundle version (restart the session to
    # load the new ones). Never loaded (a chi older than the bundle it
    # starts with): none, and a required load failure, as the hook loader
    # does for a guardrail hook, so the calls aren't quietly unguarded.
    def too_new_bundle_rules(bundle_name, bundle, reason)
      kept = @loaded_bundle_rules[bundle_name]
      unless kept
        Log.warn(:guardrails, "bundle_rules_requires_chi", echo: "[samagotchi:guardrails] bundle #{bundle_name}: its rules are not loaded: #{reason}",
                                                           bundle: bundle_name)
        @failures.add("rules (bundle #{bundle_name})", "#{reason}; update chi (chi update) or uninstall the bundle",
                      required: true, group: :rules)
        return []
      end

      key = [bundle_name, bundle.version.to_s]
      return kept if @kept_noticed[key]

      @kept_noticed[key] = true
      Log.warn(:guardrails, "bundle_rules_kept", bundle: bundle_name, version: bundle.version.to_s,
                                                 requires_chi: bundle.requires_chi.to_s)
      @notify.call(kept_notice(bundle_name, bundle))
      kept
    end

    def kept_notice(bundle_name, bundle)
      id = @session_lookup.call&.id || "ID"
      "bundle #{bundle_name} #{bundle.version} needs chi #{bundle.requires_chi} and this session runs chi #{Samagotchi::VERSION}: " \
        "its new rules are not loaded, the ones loaded before still apply. Restart the session to load them " \
        "(chi sessions stop #{id}, then chi --resume #{id})"
    end

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
      section = Samagotchi::ConfigFile.section("guardrails")
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
                            enabled: Samagotchi::Config.get("guardrails.enabled") != false,
                            mode: Samagotchi::Config.get("guardrails.mode") || "auto")
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
