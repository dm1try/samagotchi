# frozen_string_literal: true

require_relative "log"
require_relative "memory_paths"
require_relative "model_overlay"
require_relative "muted_memories"
require_relative "toolkit"
require "yaml"

module Samagotchi
  # An Engine's session toolkit: the kits it resolves against, what the
  # session's next turn declares (#explained, the UIs' summary), a plugin's
  # ctx.use_toolkit (#use) and the turn-start apply into the tool Registry
  # (#apply!), with its load warnings said once per process.
  #
  # What it needs from the Engine comes through lookups, called at use.
  class ToolkitBinding
    # @param tools        [#call] → Tools::Registry
    # @param session      [#call] → Session, nil
    # @param state_dir    [#call] → the sessions' state dir (#use saves there)
    # @param can_stage    [#call] → whether a plugin may change the toolkit now
    #   (no turn runs, no model reply yet)
    # @param reset_prompt [#call] → build the system prompts again
    # @param refresh_index [#call] → the tool index's search tool described
    #   for the Registry's toolkit (Tools::ToolIndex#refresh!)
    # @param emit         [#call] (sink, event) → emits to a turn's sink + observers
    # @param notify       [#call] (text, level, source, extra:) → a notice
    def initialize(tools:, session:, state_dir:, can_stage:, reset_prompt:, emit:, notify:, refresh_index: -> {})
      @tools = tools
      @session = session
      @state_dir = state_dir
      @can_stage = can_stage
      @reset_prompt = reset_prompt
      @refresh_index = refresh_index
      @emit = emit
      @notify = notify
      # The toolkits plugins declare (chi.toolkit), beside the built-in and
      # config ones (#kits); Plugin::Registries appends to it.
      @plugin_kits = []
      @warned = []
    end

    # @return [Array<Toolkit::Kit>] the plugins' kits (Plugin::Registries' toolkits:)
    attr_reader :plugin_kits

    # The kits a session's toolkit resolves against: built-ins, config,
    # plugins, then project and system memory kits. Config and memory kits
    # are read once per worker, like the plugins': edits take effect when a
    # new worker reads them.
    # @param errors [Array<String>] gets a line per invalid or skipped kit
    # @return [Hash{String => Toolkit::Kit}]
    def kits(errors = [])
      @config_kits = Toolkit.config_kits unless defined?(@config_kits)
      memory_kits, memory_errors = memory_kits_for(@session.call)
      errors.concat(memory_errors)
      kits = Toolkit.kits(config: @config_kits, plugins: @plugin_kits, errors: errors)
      memory_kits.each do |kit|
        if kits.key?(kit.name)
          errors << "#{MEMORY_KIT_PREFIX}#{kit.name}.md (#{kit.source}): " \
                    "toolkit name is already defined; skipping this memory kit"
        else
          kits[kit.name] = kit
        end
      end
      kits
    end

    # The session's toolkit resolved (Toolkit::Resolved): what its next
    # turn declares. A plain full toolkit is nil, the Registry's "every
    # tool"; a kit on full's tools with a prompt text is not (its text
    # reaches the prompt).
    def resolved(session, errors = [])
      resolved = Toolkit.of(session&.toolkit).resolve(kits(errors))
      resolved.everything? ? nil : resolved
    end

    # +toolkit+ (the session's by default) as its next turn would declare
    # it (/toolkit, the UIs' chip).
    # @return [Toolkit::Explained]
    def explained(toolkit = nil)
      toolkit ||= Toolkit.of(@session.call&.toolkit)
      resolved = toolkit.resolve(kits)
      filter = resolved.everything? ? nil : resolved
      tools = @tools.call
      Toolkit::Explained.new(toolkit: toolkit, resolved: resolved, declared: tools.entries(toolkit: filter),
                             left_out: tools.left_out_names(toolkit: filter),
                             reachable: tools.reachable_names(toolkit: filter),
                             removed: tools.removed_names(toolkit: filter), pending: filter != tools.toolkit)
    end

    # The session's toolkit for the UIs (the snapshot, command_ran): nil on
    # full, or with no session.
    def summary
      @session.call && explained.summary
    end

    # The session's toolkit name, nil with no session (ctx.toolkit).
    def name
      session = @session.call
      session && Toolkit.of(session.toolkit).name
    end

    # A plugin's ctx.use_toolkit: put the session on toolkit +name+, saved,
    # when it has no model reply yet and no turn runs (D3: no confirm from
    # plugins), and tell the user as /toolkit would; it applies at the next
    # turn's start.
    # @return [Boolean] whether it was staged
    # @raise [ArgumentError] an unknown toolkit
    def use(name)
      raise ArgumentError, "no toolkit named #{name}" unless kits.key?(name)

      session = @session.call
      return false if session.nil? || !@can_stage.call

      toolkit = Toolkit.new(name: name)
      if session.toolkit == toolkit
        if session.toolkit_origin != "chosen"
          session.toolkit_origin = "chosen"
          session.save(state_dir: @state_dir.call)
        end
        return true
      end

      session.toolkit = toolkit
      session.toolkit_origin = "chosen"
      session.save(state_dir: @state_dir.call)
      @notify.call("toolkit: #{name} from the next turn's start", :info, "toolkit", extra: { toolkit: summary })
      true
    end

    # Resolve the session's toolkit into the Registry, on the turn thread at
    # a turn's start (before its prompt is built), and build the prompts
    # again when what it declares (or its kit's prompt text) changed. A
    # name that doesn't resolve (a typo, an uninstalled bundle) declares
    # everything for now and says so once; the saved toolkit stays as it is.
    # @return [Boolean] whether the declared tools (or the kit's prompt text) changed
    def apply!(session, on_event = nil)
      errors = []
      resolved = Toolkit.of(session&.toolkit).resolve(kits(errors))
      warn_unresolved(session, resolved, errors, on_event)
      warn_unknown_groups(resolved, on_event)
      resolved = nil if resolved.everything?
      tools = @tools.call
      tools.reaching_kit = ->(group) { reaching_kit(group) }
      return false if resolved == tools.toolkit

      tools.toolkit = resolved
      @refresh_index.call
      @reset_prompt.call
      true
    end

    # The first kit that resolves and reaches source group +group+, the
    # user's own (config's, the plugins') before the built-ins, so a hint
    # names "/toolkit web" rather than "full"; nil when none does.
    def reaching_kit(group)
      kits = self.kits
      builtin = Toolkit::BUILTIN_KITS.keys
      kits.keys.sort_by.with_index { |name, i| [builtin.include?(name) ? 1 : 0, i] }.find do |name|
        Toolkit.resolve_kit(name, kits).reaches_group?(group)
      rescue Toolkit::Unresolved
        false
      end
    end

    private

    MEMORY_KIT_PREFIX = "toolkit_"
    MEMORY_KIT_KEYS = %w[base add remove groups description].freeze
    MEMORY_KIT_BLOCK = /\A[ \t]*```yaml[ \t]*\r?\n(.*?)\r?\n```[ \t]*\r?\n?\z/m

    # Read once per (folder, muted names): a call before the session exists
    # (no project folder yet) never hides the project's kits afterwards.
    def memory_kits_for(session)
      key = [session&.working_directory, MutedMemories.normalize_list(session&.muted_memory_names)]
      @memory_kits = { key => load_memory_kits(*key) } unless @memory_kits&.key?(key)
      @memory_kits[key]
    end

    def load_memory_kits(cwd, muted)
      candidates = []
      errors = []
      scopes = []
      scopes << ["project", MemoryPaths.scope_dir(:project, cwd: cwd)] if cwd
      scopes << ["system", MemoryPaths.scope_dir(:system, cwd: cwd)]
      scopes.each do |scope, dir|
        next unless dir && File.directory?(dir)

        Dir.glob(File.join(dir, "#{MEMORY_KIT_PREFIX}*.md")).sort.each do |path|
          next if ModelOverlay.overlay_file?(path)

          memory_name = File.basename(path, ".md")
          next if MutedMemories.muted?(memory_name, muted)

          kit = read_memory_kit(path, scope, errors)
          candidates << kit if kit
        end
      end
      [candidates, errors]
    end

    def read_memory_kit(path, scope, errors)
      memory_name = File.basename(path, ".md")
      name = memory_name.delete_prefix(MEMORY_KIT_PREFIX)
      return memory_kit_error(errors, memory_name, scope, "toolkit name is empty") if name.empty?

      body = File.read(path, encoding: "UTF-8")
      match = body.match(MEMORY_KIT_BLOCK)
      return memory_kit_error(errors, memory_name, scope, "expected one fenced yaml block") unless match

      spec = YAML.safe_load(match[1], permitted_classes: [], aliases: false)
      return memory_kit_error(errors, memory_name, scope, "yaml block must be a map") unless spec.is_a?(Hash)

      spec = spec.transform_keys(&:to_s)
      if spec.key?("prompt")
        return memory_kit_error(errors, memory_name, scope, "prompt: is not supported in toolkit memories")
      end

      unknown = spec.keys - MEMORY_KIT_KEYS
      if unknown.any?
        return memory_kit_error(errors, memory_name, scope, "unknown key #{unknown.first}")
      end

      description = spec["description"]
      unless spec.key?("description") && !description.nil?
        return memory_kit_error(errors, memory_name, scope, "description is required")
      end
      if (problem = Toolkit.description_error(description))
        return memory_kit_error(errors, memory_name, scope, problem)
      end
      return memory_kit_error(errors, memory_name, scope, "description is required") if description.strip.empty?
      if !spec["base"].nil? && (!spec["base"].is_a?(String) || spec["base"].strip.empty?)
        return memory_kit_error(errors, memory_name, scope, "base must be a toolkit name")
      end
      if %w[add remove].any? { |key| spec.key?(key) && !(spec[key].is_a?(Array) && spec[key].all?(String)) }
        return memory_kit_error(errors, memory_name, scope, "add and remove must be lists of tool names")
      end
      if (problem = Toolkit.groups_error(spec["groups"]))
        return memory_kit_error(errors, memory_name, scope, problem)
      end

      Toolkit::Kit.new(name: name, base: spec["base"] || Toolkit::FULL, add: spec.fetch("add", []),
                       remove: spec.fetch("remove", []), groups: spec["groups"], description: description,
                       source: "memory:#{scope}")
    rescue Psych::Exception, SystemCallError, EncodingError => e
      memory_kit_error(errors, memory_name, scope, e.message.lines.first.to_s.strip)
    end

    def memory_kit_error(errors, memory_name, scope, message)
      errors << "#{memory_name} (memory:#{scope}): #{message}"
      nil
    end

    # The toolkit's load warnings, each once per process: a name that
    # didn't resolve, config kits left out.
    def warn_unresolved(session, resolved, errors, on_event)
      lines = errors.dup
      if resolved.fallback
        lines << "#{Toolkit.of(session&.toolkit).label}: #{resolved.fallback}; this session declares every tool (full) " \
                 "until it resolves"
      end
      (lines - @warned).each do |line|
        @warned << line
        Log.warn(:config, "toolkit_unresolved", message: line)
        @emit.call(on_event, { type: :guardrail_warning, message: line, label: "toolkit" })
      end
    end

    def warn_unknown_groups(resolved, on_event)
      return if resolved.groups == :all

      names = @tools.call.index&.groups || []
      unknown = resolved.groups.reject do |selector|
        names.any? { |name| Toolkit.group_matches?([selector], name) }
      end
      unknown.each do |selector|
        line = "#{resolved.name}: group selector #{selector.inspect} matches no group declared at load"
        next if @warned.include?(line)

        @warned << line
        Log.warn(:config, "toolkit_group_unknown", message: line)
        @emit.call(on_event, { type: :guardrail_warning, message: line, label: "toolkit" })
      end
    end
  end
end
