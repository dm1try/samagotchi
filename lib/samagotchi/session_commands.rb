# frozen_string_literal: true

require "set"

require_relative "config"
require_relative "model_profile"
require_relative "served_model"
require_relative "turn_flow"
require_relative "tools/execute"

module Samagotchi
  # The session commands a REPL and a session worker both run: /model,
  # /models, /guardrails, !rollback, !cmd and the answer to a continue offer. They act on
  # the Engine and its TurnFlow; the host prints the result's output and
  # runs a continue turn when asked to (#run never runs a turn).
  #
  # /stats, /recap and /exit are the UI's own, not here.
  class SessionCommands
    MODEL_COMMAND = "/model"
    MODELS_COMMAND = "/models"
    GUARDRAILS_COMMAND = "/guardrails"
    # A remote catalog has hundreds of ids (OpenRouter ~380): plain /models
    # shows this many per host; /models <text> lists every match.
    MODELS_PER_HOST = 20
    ROLLBACK_COMMAND = "!rollback"
    CONTINUE_COMMAND = TurnFlow::CONTINUE_COMMAND
    SHELL_BANG_PREFIX = "!"
    RESERVED_MODEL_ARGS = %w[clear default none off].freeze
    ALIAS_USAGE = "usage /model <model> --alias <name> [--default]"

    # @!attribute status [Symbol] :ok, or :error when the line was refused
    # @!attribute output [String, nil] what to tell the user
    # @!attribute changed [Array<Symbol>] :messages and/or :model
    # @!attribute model_name [String] the Engine's model after the command
    # @!attribute resume [Boolean] the host must now run the continue turn
    # @!attribute shell [Boolean] output is a !cmd's own output
    # @!attribute decision [Symbol, nil] an answer to the continue offer:
    #   :resume, :abort, :abort_with_reason or :invalid
    Result = Struct.new(:status, :output, :changed, :model_name, :resume, :shell, :decision, keyword_init: true)

    # @return [Boolean] whether +line+ is one of these commands
    def self.command?(line)
      !kind_of_line(line).nil?
    end

    def self.kind_of_line(line)
      text = line.to_s.strip
      return :rollback if text == ROLLBACK_COMMAND
      return :shell if text.match?(/\A!\s*\S/)
      return :continue if text == CONTINUE_COMMAND || text.start_with?("#{CONTINUE_COMMAND} ")
      return :models if text == MODELS_COMMAND || text.start_with?("#{MODELS_COMMAND} ")
      return :guardrails if text == GUARDRAILS_COMMAND || text.start_with?("#{GUARDRAILS_COMMAND} ")
      return :model if text.match?(/\A\/model(?:\s+.*)?\z/)

      nil
    end

    # @return [String] the model /model clear goes back to
    attr_reader :default_model

    # @param default_model [String] the config default, which /model clear
    #   restores and /model names (the Engine may have started elsewhere, e.g.
    #   on a resumed session's model)
    # @param save [#call] saves a session (a worker passes its state dir)
    def initialize(engine:, turn_flow:, default_model:, save: ->(session) { session.save })
      @engine = engine
      @turn_flow = turn_flow
      @default_model = default_model
      @save = save
    end

    # @return [Result, nil] nil when +line+ is not one of these commands
    def run(line)
      text = line.to_s.strip
      case self.class.kind_of_line(text)
      when :rollback then rollback
      when :shell then shell(text)
      when :continue
        return reply("nothing to continue") unless @turn_flow.awaiting_continue?

        answer = text.delete_prefix(CONTINUE_COMMAND).strip
        continue_answer(answer.empty? ? CONTINUE_COMMAND : answer)
      when :models then reply(models_listing(text.delete_prefix(MODELS_COMMAND).strip))
      when :guardrails then guardrails(text.delete_prefix(GUARDRAILS_COMMAND).strip)
      when :model then model(text)
      end
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
                 reply("interrupted turn cancelled; enter your next prompt", changed: [:messages])
               when :abort_with_reason
                 @turn_flow.abort_continue!(reason: reason)
                 save_session
                 reply("interrupted turn cancelled; noted your explanation", changed: [:messages])
               else
                 reply("answer yes, no, or no, <reason>", status: :error)
               end
      result.decision = decision
      result
    end

    private

    def model_name = @engine.effective_model_name

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
          ("path #{rule.path}" if rule.path)
        ].compact.join(", ")
        off = "disabled (guardrails.disable) — " if rules.disabled?(rule)
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

      session.model_name = model_name
      @save.call(session)
    end

    def model(text)
      output, switched = model_command(text)
      reply(output, changed: switched ? [:model] : [])
    end

    # @return [Array(String, Boolean)] the message, and whether the model changed
    def model_command(input)
      suffix = input.delete_prefix(MODEL_COMMAND).strip
      if suffix.empty?
        return ["runtime model: #{model_name}#{model_note}#{served_note}", false] if model_name == @default_model

        return ["runtime model: #{model_name}#{model_note("default: #{@default_model}")}#{served_note}", false]
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
        return ["--alias cannot be combined with clear/default/none/off", false] if RESERVED_MODEL_ARGS.include?(arg.downcase)

        # Validate the alias before switching, so a bad one changes nothing.
        invalid = alias_name_error(alias_name, arg)
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

        if RESERVED_MODEL_ARGS.include?(arg.downcase)
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

    # Mirrors ConfigFile.write_model_alias!'s checks without writing.
    # @return [String, nil] what is wrong with the alias name
    def alias_name_error(alias_name, target)
      ak = alias_name.strip
      return "alias name is required" if ak.empty?

      lk = ak.downcase
      return "alias name '#{ak}' is reserved" if RESERVED_MODEL_ARGS.include?(lk)
      return "alias name must not contain whitespace" if ak.match?(/\s/)
      return "alias name must not start with '-'" if ak.start_with?("-")
      return "alias name must not contain '/'" if ak.include?("/")
      return "alias name must match /[a-z0-9][a-z0-9._-]*/i (got '#{ak}')" unless ak.match?(/\A[a-z0-9][a-z0-9._-]*\z/i)
      return "alias must not point to itself" if lk == target.strip.downcase

      nil
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
      return unless session.respond_to?(:model_name=)

      session.model_name = model_name
      begin
        @save.call(session)
      rescue StandardError
        nil
      end
    end

    # "; served: <name>" when the server serves another model than asked.
    def served_note
      served, asked = @engine.respond_to?(:served_model) ? @engine.served_model : nil
      ServedModel.differs?(asked, served) ? "; served: #{served}" : ""
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
      @engine.respond_to?(:chat_model?) && @engine.chat_model?
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
      aliases.each do |alias_name, model_id|
        # normalize bare comparison for orphan detection (strip host prefix if present)
        _, bare = registry.parse_qualified_model(model_id)
        key = (bare.empty? ? model_id : bare).to_s.downcase
        by_model[key] << alias_name
        # also index full ref for exact alias display
        by_model[model_id.downcase] << alias_name unless key == model_id.downcase
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
          seen << "#{hname}/#{identifier}".downcase
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
      orphans = aliases.reject { |_, model_id| seen.include?(model_id.downcase) || seen.include?(registry.bare_name(model_id).downcase) }
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
