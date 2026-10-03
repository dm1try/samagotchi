# frozen_string_literal: true

require "set"

require_relative "config"
require_relative "model_profile"
require_relative "served_model"
require_relative "turn_flow"
require_relative "tools/execute"
require_relative "commands/registry"

module Samagotchi
  # The session commands a REPL and a session worker both run: /model,
  # /models, /guardrails, !rollback, !cmd and the answer to a continue offer. They act on
  # the Engine and its TurnFlow; the host prints the result's output and
  # runs a continue turn when asked to (#run never runs a turn).
  #
  # /stats, /recap, /exit, /quit, /archive and /detach are the terminal
  # UIs' own: they are in the registry (local:) for Tab and help, and so
  # both TUIs read the same words (Registry#lookup_local gives the entry,
  # its id says what to do), but #run never runs them.
  class SessionCommands
    MODEL_COMMAND = "/model"
    MODELS_COMMAND = "/models"
    GUARDRAILS_COMMAND = "/guardrails"
    HELP_COMMAND = "/help"
    # A remote catalog has hundreds of ids (OpenRouter ~380): plain /models
    # shows this many per host; /models <text> lists every match.
    MODELS_PER_HOST = 20
    ROLLBACK_COMMAND = "!rollback"
    CONTINUE_COMMAND = TurnFlow::CONTINUE_COMMAND
    SHELL_BANG_PREFIX = "!"
    ALIAS_USAGE = "usage /model <model> --alias <name> [--default]"
    # /exit --delete: delete the session on the way out.
    EXIT_DELETE_FLAG = "--delete"

    # @!attribute status [Symbol] :ok, or :error when the line was refused
    # @!attribute output [String, nil] what to tell the user
    # @!attribute changed [Array<Symbol>] :messages and/or :model
    # @!attribute model_name [String] the Engine's model after the command
    # @!attribute resume [Boolean] the host must now run the continue turn
    # @!attribute shell [Boolean] output is a !cmd's own output
    # @!attribute decision [Symbol, nil] an answer to the continue offer:
    #   :resume, :abort, :abort_with_reason or :invalid
    Result = Struct.new(:status, :output, :changed, :model_name, :resume, :shell, :decision, keyword_init: true)

    # Puts the built-in commands into +registry+, in lookup order (!rollback
    # before !cmd): the ones #run runs, then the UIs' own (local: Tab and
    # help only).
    def self.register_builtins(registry)
      registry.register(ROLLBACK_COMMAND, "discard the interrupted turn and restore the pre-turn state",
                        id: :rollback) { |_text| rollback }
      registry.register("!", "run a shell command; its output goes into the conversation",
                        id: :shell, match: ->(text) { text.match?(/\A!\s*\S/) }) { |text| shell(text) }
      registry.register(CONTINUE_COMMAND, "answer the continue offer (yes, no or no, <reason>)") do |text|
        next reply("nothing to continue") unless @turn_flow.awaiting_continue?

        answer = text.delete_prefix(CONTINUE_COMMAND).strip
        continue_answer(answer.empty? ? CONTINUE_COMMAND : answer)
      end
      registry.register(MODELS_COMMAND, "list the hosts' models (/models <text> filters)") do |text|
        reply(models_listing(text.delete_prefix(MODELS_COMMAND).strip))
      end
      registry.register(GUARDRAILS_COMMAND, "list the guardrail rules and approvals (/guardrails revoke N)") do |text|
        guardrails(text.delete_prefix(GUARDRAILS_COMMAND).strip)
      end
      registry.register(MODEL_COMMAND, "show or switch the model",
                        match: ->(text) { text.match?(/\A\/model(?:\s+.*)?\z/) }) { |text| model(text) }
      registry.register(HELP_COMMAND, "list the commands, the bundles' too", anytime: true) { |_text| reply(help_listing) }
      registry.register("/stats", "show the session's stats", local: true)
      registry.register("/recap", "show the session's recap", local: true)
      # Bare `exit` too; any case; --delete after it.
      registry.register("/exit", "leave (--delete also deletes the session)", local: true,
                                                                              match: exit_match("/?exit"))
      registry.register("/quit", "leave, like /exit", id: :exit, local: true, match: exit_match("/quit"))
      registry.register("/archive", "leave and archive the session: hidden from the lists, kept for good", local: true,
                                                                                                          match: ->(text) { text.casecmp?("/archive") })
      # The REPL owns its session: it answers /detach with a note, and doesn't offer it.
      registry.register("/detach", "leave and keep the worker running", local: true, uis: [:attached],
                                                                        match: ->(text) { text.casecmp?("/detach") })
      registry
    end

    # @param word [String] the regexp source of the exit word
    def self.exit_match(word)
      pattern = /\A#{word}(?:\s+#{EXIT_DELETE_FLAG})?\z/i
      ->(text) { text.match?(pattern) }
    end
    private_class_method :exit_match

    # @return [Boolean] an exit line (/exit, /quit, exit) that deletes the session too
    def self.delete_on_exit?(line) = line.to_s.split.last.to_s.casecmp?(EXIT_DELETE_FLAG)

    # The built-ins alone, for callers without an Engine (an attached TUI
    # before its snapshot names the session's commands, specs).
    # @return [Commands::Registry] frozen
    def self.builtin_registry
      @builtin_registry ||= register_builtins(Commands::Registry.new).freeze
    end

    # @return [String] the model /model clear goes back to
    attr_reader :default_model

    # @param default_model [String] the config default, which /model clear
    #   restores and /model names (the Engine may have started elsewhere, e.g.
    #   on a resumed session's model)
    # @param save [#call] saves a session (a worker passes its state dir)
    # @param registry [Commands::Registry] the commands #run looks lines up in
    def initialize(engine:, turn_flow:, default_model:, save: ->(session) { session.save },
                   registry: self.class.builtin_registry)
      @engine = engine
      @turn_flow = turn_flow
      @default_model = default_model
      @save = save
      @registry = registry
    end

    # @return [Commands::Registry]
    attr_reader :registry

    # /help: every command in the registry, the UIs' own and the bundles'
    # too: the session's commands first, then the bundles', then the UIs'
    # own (marked by UI), each group by name.
    # @return [String]
    def help_listing
      entries = @registry.entries.sort_by { |entry| [help_group(entry), entry.name] }
      width = entries.map { |entry| self.class.display_name(entry).length }.max
      lines = entries.map do |entry|
        notes = []
        notes << entry.source unless entry.source == "core"
        notes << "mid-turn too" if entry.anytime
        notes << (entry.uis ? "#{entry.uis.join(" and ")} only" : "terminal only") if entry.local
        line = "  #{self.class.display_name(entry).ljust(width)}  #{entry.description}"
        notes.empty? ? line : "#{line}  (#{notes.join("; ")})"
      end
      "commands:\n#{lines.join("\n")}"
    end

    # How help and errors name an entry (the shell's "!" is "!<cmd>").
    def self.display_name(entry) = entry.name == SHELL_BANG_PREFIX ? "#{SHELL_BANG_PREFIX}<cmd>" : entry.name

    # @return [Result, nil] nil when +line+ is not one of these commands
    def run(line)
      text = line.to_s.strip
      entry = @registry.lookup(text)
      return nil unless entry&.handler
      return run_bundle_command(entry, text) unless entry.source == "core"

      instance_exec(text, &entry.handler)
    end

    # Answer the pending continue offer (yes / no / no, <reason>).
    # @return [Result] resume: true on yes
    def continue_answer(text)
      decision, reason = TurnFlow.continue_decision(text)
      result = case decision
               when :resume then Result.new(status: :ok, changed: [], model_name: model_name, resume: true, shell: false)
               when :abort
                 @turn_flow.abort_continue!
                 save_session
                 reply("turn not continued; its work so far stays (!rollback erases it)", changed: [:messages])
               when :abort_with_reason
                 @turn_flow.abort_continue!(reason: reason)
                 save_session
                 reply("turn not continued; noted your reason", changed: [:messages])
               else
                 reply("answer yes, no, or no, <reason>", status: :error)
               end
      result.decision = decision
      result
    end

    private

    # The resolved ref (what the session stores and --alias/--default write).
    def model_name = @engine.effective_model_ref

    # A bundle plugin's command: its handler gets the text after the name;
    # what it returns is the output (nil: nothing to show), and a raise is
    # an error result.
    def run_bundle_command(entry, text)
      output = entry.handler.call(text.delete_prefix(entry.name).strip)
      reply(output.nil? ? nil : output.to_s)
    rescue StandardError => e
      reply("#{entry.name}: #{e.class}: #{e.message}", status: :error)
    end

    def help_group(entry)
      return 2 if entry.local

      entry.source == "core" ? 0 : 1
    end

    def reply(output, status: :ok, changed: [])
      Result.new(status: status, output: output, changed: changed, model_name: model_name, resume: false, shell: false)
    end

    # Explicit escape hatch after a Ctrl-C: discard the salvaged partial
    # turn and restore the pre-turn checkpoint.
    def rollback
      offered = @turn_flow.awaiting_continue?
      return reply("nothing to rollback") unless @turn_flow.rollback!

      save_session
      result = reply("salvaged turn discarded; restored pre-turn state", changed: [:messages])
      # It discarded the turn a continue was offered for: that offer's no.
      result.decision = :abort if offered
      result
    end

    # The output goes into the conversation for the next turn. Not saved
    # here (as in the REPL, the next turn saves it).
    def shell(text)
      command = text.delete_prefix(SHELL_BANG_PREFIX).strip
      return reply("!: please provide a shell command after '!'", status: :error) if command.empty?

      output = Samagotchi::Tools::Execute.call(command)
      @engine.append_messages([{ role: "user", content: "!(#{command})\n#{output}" }])
      # Rolling back past this would silently drop the command output.
      @turn_flow.note_conversation_changed
      Result.new(status: :ok, output: output, changed: [:messages], model_name: model_name, resume: false, shell: true)
    end

    # /guardrails: the rules (by source), what failed to load, the stored
    # approvals, numbered; /guardrails revoke N removes approval N.
    def guardrails(args)
      return guardrails_revoke(args.delete_prefix("revoke").strip) if args.start_with?("revoke")
      return reply("usage: /guardrails [revoke N]", status: :error) unless args.empty?

      reply(guardrails_listing)
    end

    def guardrails_listing
      rules = @engine.guardrail_rules
      approvals = @engine.guardrail_approvals.entries
      lines = ["guardrails: #{rules.enabled? ? "on" : "off (guardrails.enabled: false; denies still apply)"}"]
      name = @engine.guardrail_model_name
      key = @engine.model_key
      lines << "model: #{name || "none"} — #{Guardrails::ModelSize.describe(name, key)}"
      failures = @engine.guardrail_failures.list
      unless failures.empty?
        lines << "failed to load:"
        failures.each do |f|
          lines << "  #{f.what}: #{f.reason}#{" (required: every tool call is denied)" if f.required}"
        end
      end
      disabled = rules.rules.count { |rule| rules.disabled?(rule) }
      lines << "rules (#{rules.rules.size}#{", #{disabled} disabled" if disabled.positive?}):"
      lines << "  (none; add them under guardrails.rules in config.yml, or install a bundle that ships them)" if rules.rules.empty?
      rules.rules.each_with_index do |rule, idx|
        match = [
          ("tool #{rule.tools.join(",")}" if rule.tools),
          ("command /#{shorten_pattern(rule.command.source)}/" if rule.command),
          ("path #{rule.path}" if rule.path),
          ("models #{rule.models.join(",")}" if rule.models)
        ].compact.join(", ")
        off = "disabled (guardrails.disable) — " if rules.disabled?(rule)
        off ||= "off for this model — " unless rule.for_model?(name, key)
        lines << "  #{idx + 1}. #{rule.id}: #{off}#{rule.verdict} (#{match}) — #{rule.reason} [#{rule.source}]"
      end
      rules.unmatched_disables.each { |entry| lines << "  guardrails.disable: #{entry} matches no rule" }
      lines << "  core: deny writes to the approval store and installed bundles; ask before editing config.yml or the hooks dir"
      lines << "approvals (#{approvals.size}):"
      lines << "  (none)" if approvals.empty?
      approvals.each_with_index { |entry, idx| lines << "  #{idx + 1}. #{approval_line(entry)}" }
      lines << "revoke one with /guardrails revoke N" unless approvals.empty?
      lines.join("\n")
    end

    PATTERN_SHOWN = 80

    # A regex source cut to PATTERN_SHOWN characters, the last one "…".
    def shorten_pattern(source)
      source.length > PATTERN_SHOWN ? "#{source[0, PATTERN_SHOWN - 1]}…" : source
    end

    def approval_line(entry)
      what = entry["key"] ? entry["key"].tr("\n", " ") : "any call rule #{entry["rule"]} asks about"
      where = entry["scope"] == "session" ? "session #{entry["session_id"].to_s[0, 8]}" : "in #{entry["repo_root"]}"
      rule = entry["rule"] ? " (rule #{entry["rule"]}, #{entry["source"]})" : ""
      "#{entry["scope"]}: #{what} — #{where}#{rule}, #{entry["created_at"]}"
    end

    def guardrails_revoke(arg)
      return reply("usage: /guardrails revoke N (N from /guardrails)", status: :error) unless arg.match?(/\A\d+\z/)

      removed = @engine.guardrail_approvals.revoke(arg.to_i - 1)
      return reply("no approval #{arg} (see /guardrails)", status: :error) unless removed

      reply("revoked approval #{arg}: #{approval_line(removed)}")
    end

    def save_session
      session = @engine.session
      return unless session

      @engine.store_model!(session)
      @save.call(session)
    end

    def model(text)
      output, switched = model_command(text)
      reply(output, changed: switched ? [:model] : [])
    rescue ModelProfile::MissingModel => e
      # A model qualified with an unknown host: nothing switched.
      reply(e.message, status: :error)
    end

    # @return [Array(String, Boolean)] the message, and whether the model changed
    def model_command(input)
      suffix = input.delete_prefix(MODEL_COMMAND).strip
      if suffix.empty?
        return ["runtime model: #{model_name}#{model_note}#{served_note}#{sampling_note}#{thinking_note}", false] if model_name == @engine.model_ref_for(@default_model)

        return ["runtime model: #{model_name}#{model_note("default: #{@default_model}")}#{served_note}#{sampling_note}#{thinking_note}", false]
      end

      # Parse flags: --default and --alias <name> / --alias=<name> (tolerant order)
      tokens = suffix.split(/\s+/)
      persist_default = false
      alias_name = nil
      alias_seen = false
      model_parts = []
      i = 0
      while i < tokens.length
        tok = tokens[i]
        if tok == "--default"
          persist_default = true
          i += 1
        elsif tok == "--alias"
          return ["multiple --alias flags are not supported: #{ALIAS_USAGE}", false] if alias_seen

          alias_seen = true
          nxt = tokens[i + 1]
          return ["--alias requires a name: #{ALIAS_USAGE}", false] if nxt.nil? || nxt.strip.empty? || nxt.start_with?("-")

          alias_name = nxt.strip
          i += 2
        elsif tok.start_with?("--alias=")
          return ["multiple --alias flags are not supported: #{ALIAS_USAGE}", false] if alias_seen

          alias_seen = true
          val = tok.delete_prefix("--alias=").strip
          return ["--alias requires a name: #{ALIAS_USAGE}", false] if val.empty? || val.start_with?("-")

          alias_name = val
          i += 1
        else
          model_parts << tok
          i += 1
        end
      end

      arg = model_parts.join(" ").strip

      if alias_name
        return ["--alias requires a model name: #{ALIAS_USAGE}", false] if arg.empty?
        return ["--alias cannot be combined with clear/default/none/off", false] if ConfigFile::RESERVED_MODEL_ALIASES.include?(arg.downcase)

        # Validate the alias before switching, so a bad one changes nothing.
        invalid = ConfigFile.model_alias_error(alias_name, arg)
        return ["invalid alias: #{invalid}", false] if invalid

        switch_model(arg, persist_default: persist_default)

        begin
          previous = ConfigFile.write_model_alias!(alias_name, model_name)
        rescue ArgumentError => e
          return ["invalid alias: #{e.message} (runtime model set to #{model_name}#{model_note})", true]
        rescue StandardError => e
          return ["runtime model set to #{model_name}#{model_note} but failed to persist alias: #{e.message}", true]
        end

        key = alias_name.strip.downcase
        warn_prefix = previous ? "warning: overwriting alias '#{key}' (#{previous} -> #{model_name}); " : ""
        base = persist_default ? "runtime model set to #{model_name}#{model_note} and default updated" : "runtime model set to #{model_name}#{model_note}"
        ["#{warn_prefix}#{base}; alias '#{key}' -> '#{model_name}' persisted", true]
      else
        return ["--default requires a model name: usage /model --default <name> or /model <name> [--default]", false] if arg.empty?

        if ConfigFile::RESERVED_MODEL_ALIASES.include?(arg.downcase)
          return ["--default cannot be combined with clear/default/none/off", false] if persist_default

          switch_model(@default_model)
          return ["runtime model reset to #{model_name}#{model_note}", true]
        end

        switch_model(arg, persist_default: persist_default)
        if persist_default
          ["runtime model set to #{model_name}#{model_note} and default updated", true]
        else
          ["runtime model set to #{model_name}#{model_note}", true]
        end
      end
    end

    # Engine owns the switch (alias resolution, profile, kernel, client and
    # the optional default persist); the session keeps the new model.
    def switch_model(name, persist_default: false)
      @engine.switch_model!(name, persist_default: persist_default)
      @default_model = @engine.default_model_name if persist_default
      persist_session_model
    end

    def persist_session_model
      session = @engine.session
      return unless session

      @engine.store_model!(session)
      begin
        @save.call(session)
      rescue StandardError
        nil
      end
    end

    # "; served: <name>" when the server serves another model than asked.
    def served_note
      served, asked = @engine.served_model
      ServedModel.differs?(asked, served) ? "; served: #{served}" : ""
    rescue StandardError
      ""
    end

    # "; sampling: temperature=0.6 (hosts.work)" when the model has any.
    def sampling_note
      summary = @engine.sampling_summary
      summary ? "; sampling: #{summary}" : ""
    rescue StandardError
      ""
    end

    # "; thinking: off (models: qwen)" when the model has a level set.
    def thinking_note
      summary = @engine.thinking_summary
      summary ? "; thinking: #{summary}" : ""
    rescue StandardError
      ""
    end

    # " (default: x, profile=qwen36, name)": +extra+ and the prompt profile,
    # which a chat host's model doesn't have (its loop uses none); "" when
    # there is neither.
    def model_note(extra = nil)
      parts = [extra, (profile_note unless chat_model?)].compact
      parts.empty? ? "" : " (#{parts.join(", ")})"
    end

    def chat_model?
      @engine.chat_model?
    rescue StandardError
      false
    end

    # "profile=qwen36, server (chat_template)": the profile and where it came from.
    def profile_note
      resolution = @engine.profile_resolution
      "profile=#{resolution.profile.name}, #{resolution.label}"
    end

    # @param filter [String] only ids containing it (any case); "" lists
    #   up to MODELS_PER_HOST per host
    def models_listing(filter = "")
      needle = filter.downcase
      registry = @engine.host_registry
      # Aggregate across all hosts (lazy discovery, skip-on-error)
      results = registry.list_all_models
      return "no hosts configured" if results.nil? || results.empty?

      aliases = ConfigFile.model_aliases
      by_model = Hash.new { |h, k| h[k] = [] }
      # A bare alias shows next to its id on every host, a host:model one
      # only under its host.
      aliases.each do |alias_name, model_id|
        host, bare = registry.parse_qualified_model(model_id)
        by_model[host ? "#{host}:#{bare}".downcase : model_id.downcase] << alias_name
      end
      by_model.each_value { |v| v.uniq!; v.sort! }

      seen = Set.new
      lines = []
      # Sort hosts for deterministic output
      results.keys.sort.each do |hname|
        data = results[hname]
        host_label = "#{hname} (#{data[:host]}:#{data[:port]})"
        if data[:error]
          lines << "#{host_label} — unreachable: #{data[:error]}"
          next
        end
        models = Array(data[:models])
        if models.empty?
          lines << "#{host_label} — no models discovered"
          next
        end
        shown = []
        batch_variants = batch_variant_ids(models, needle)
        models.each do |entry|
          identifier = entry.id.to_s.empty? ? "unknown" : entry.id
          seen << identifier.to_s.downcase
          # also track host-qualified seen for orphan logic
          seen << "#{hname}:#{identifier}".downcase
          next if batch_variants.include?(identifier)

          shown << [entry, identifier] if needle.empty? || identifier.to_s.downcase.include?(needle)
        end
        next if shown.empty?

        lines << "#{host_label}:"
        hidden = needle.empty? ? [shown.size - MODELS_PER_HOST, 0].max : 0
        shown.first(shown.size - hidden).each do |entry, identifier|
          raw_status = entry.raw["status"] || entry.raw[:status]
          status = raw_status.is_a?(Hash) ? (raw_status["value"] || raw_status[:value] || raw_status["status"] || raw_status[:status]) : raw_status
          base = status.to_s.empty? ? "  #{identifier}" : "  #{identifier} (#{status})"
          alias_list = (by_model[identifier.to_s.downcase] || []) + (by_model["#{hname}:#{identifier}".downcase] || [])
          alias_list.uniq!
          lines << (alias_list.empty? ? base : "#{base} (alias: #{alias_list.join(", ")})")
        end
        batch = batch_variants.count { |id| needle.empty? || id.downcase.include?(needle) }
        batch_note = "#{batch} :batch variant#{"s" unless batch == 1}"
        if hidden.positive?
          more = batch.positive? ? "#{hidden} more, plus #{batch_note}" : "#{hidden} more"
          lines << "  … and #{more}; /models <text> lists the ids containing <text>"
        elsif batch.positive?
          lines << "  … plus #{batch_note}; /models :batch lists them"
        end
      end
      # Warnings for unreachable hosts are already in lines; no failover
      orphans = aliases.reject { |_, model_id| seen.include?(model_id.downcase) || seen.include?(registry.parse_qualified_model(model_id).last.downcase) }
      unless orphans.empty? || !needle.empty?
        lines << ""
        lines << "orphan aliases (target not discovered):"
        orphans.sort.each { |alias_name, model_id| lines << "  #{alias_name} -> #{model_id}" }
      end
      lines = [needle.empty? ? "no models discovered" : "no model ids contain #{filter.inspect}"] if lines.empty?
      lines.join("\n")
    rescue StandardError => e
      "unable to list models: #{e.message}"
    end

    # OpenRouter lists a "<id>:batch" variant next to many ids (71 of 457 on
    # 2026-09-23), which only repeats the model. The ids of such variants
    # whose plain id is listed too, unless the filter asks for batch.
    def batch_variant_ids(models, needle)
      return Set.new if needle.include?("batch")

      ids = models.map { |entry| entry.id.to_s }
      plain = ids.to_set
      ids.select { |id| id.end_with?(":batch") && plain.include?(id.delete_suffix(":batch")) }.to_set
    end
  end
end
