# frozen_string_literal: true

require "set"

require_relative "config"
require_relative "model_profile"
require_relative "served_model"
require_relative "turn_flow"
require_relative "tools/execute"

module Samagotchi
  # The session commands a REPL and a session worker both run: /model,
  # /models, !rollback, !cmd and the answer to a continue offer. They act on
  # the Engine and its TurnFlow; the host prints the result's output and
  # runs a continue turn when asked to (#run never runs a turn).
  #
  # /stats, /recap and /exit are the UI's own, not here.
  class SessionCommands
    MODEL_COMMAND = "/model"
    MODELS_COMMAND = "/models"
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
        return ["runtime model: #{model_name} (profile=#{profile_note})#{served_note}", false] if model_name == @default_model

        return ["runtime model: #{model_name} (default: #{@default_model}, profile=#{profile_note})#{served_note}", false]
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
          return ["invalid alias: #{e.message} (runtime model set to #{model_name} (profile=#{profile_note}))", true]
        rescue StandardError => e
          return ["runtime model set to #{model_name} (profile=#{profile_note}) but failed to persist alias: #{e.message}", true]
        end

        key = alias_name.strip.downcase
        warn_prefix = previous ? "warning: overwriting alias '#{key}' (#{previous} -> #{model_name}); " : ""
        base = persist_default ? "runtime model set to #{model_name} (profile=#{profile_note}) and default updated" : "runtime model set to #{model_name} (profile=#{profile_note})"
        ["#{warn_prefix}#{base}; alias '#{key}' -> '#{model_name}' persisted", true]
      else
        return ["--default requires a model name: usage /model --default <name> or /model <name> [--default]", false] if arg.empty?

        if RESERVED_MODEL_ARGS.include?(arg.downcase)
          return ["--default cannot be combined with clear/default/none/off", false] if persist_default

          switch_model(@default_model)
          return ["runtime model reset to #{model_name} (profile=#{profile_note})", true]
        end

        switch_model(arg, persist_default: persist_default)
        if persist_default
          ["runtime model set to #{model_name} (profile=#{profile_note}) and default updated", true]
        else
          ["runtime model set to #{model_name} (profile=#{profile_note})", true]
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

    # "qwen36, server (chat_template)": the profile and where it came from.
    # "; served: <name>" when the server serves another model than asked.
    def served_note
      served, asked = @engine.respond_to?(:served_model) ? @engine.served_model : nil
      ServedModel.differs?(asked, served) ? "; served: #{served}" : ""
    rescue StandardError
      ""
    end

    def profile_note
      resolution = @engine.profile_resolution
      "#{resolution.profile.name}, #{resolution.label}"
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
        models.each do |entry|
          identifier = entry.id.to_s.empty? ? "unknown" : entry.id
          seen << identifier.to_s.downcase
          # also track host-qualified seen for orphan logic
          seen << "#{hname}:#{identifier}".downcase
          seen << "#{hname}/#{identifier}".downcase
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
        lines << "  … and #{hidden} more; /models <text> lists the ids containing <text>" if hidden.positive?
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
  end
end
