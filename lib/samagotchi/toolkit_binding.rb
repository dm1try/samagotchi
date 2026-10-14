# frozen_string_literal: true

require_relative "log"
require_relative "toolkit"

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
    # @param emit         [#call] (sink, event) → emits to a turn's sink + observers
    # @param notify       [#call] (text, level, source, extra:) → a notice
    def initialize(tools:, session:, state_dir:, can_stage:, reset_prompt:, emit:, notify:)
      @tools = tools
      @session = session
      @state_dir = state_dir
      @can_stage = can_stage
      @reset_prompt = reset_prompt
      @emit = emit
      @notify = notify
      # The toolkits plugins declare (chi.toolkit), beside the built-in and
      # config ones (#kits); Plugin::Registries appends to it.
      @plugin_kits = []
      @warned = []
    end

    # @return [Array<Toolkit::Kit>] the plugins' kits (Plugin::Registries' toolkits:)
    attr_reader :plugin_kits

    # The kits a session's toolkit resolves against: the built-ins, config's
    # toolkit.kits, the plugins' (Toolkit.kits). Config's are read once per
    # process, like the plugins': an edit to toolkit.kits never changes a
    # live session's tools mid-session (a new worker reads it).
    # @param errors [Array<String>] gets a line per config kit left out
    # @return [Hash{String => Toolkit::Kit}]
    def kits(errors = [])
      @config_kits = Toolkit.config_kits unless defined?(@config_kits)
      Toolkit.kits(config: @config_kits, plugins: @plugin_kits, errors: errors)
    end

    # The session's toolkit resolved (Toolkit::Resolved): what its next
    # turn declares. A plain full toolkit is nil, the Registry's "every tool".
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
                             left_out: tools.left_out_names(toolkit: filter), pending: filter != tools.toolkit)
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
      return true if session.toolkit == toolkit

      session.toolkit = toolkit
      session.save(state_dir: @state_dir.call)
      @notify.call("toolkit: #{name} from the next turn's start", :info, "toolkit", extra: { toolkit: summary })
      true
    end

    # Resolve the session's toolkit into the Registry, on the turn thread at
    # a turn's start (before its prompt is built), and build the prompts
    # again when what it declares changed. A name that doesn't resolve (a
    # typo, an uninstalled bundle) declares everything for now and says so
    # once; the saved toolkit stays as it is.
    # @return [Boolean] whether the declared tools changed
    def apply!(session, on_event = nil)
      errors = []
      resolved = Toolkit.of(session&.toolkit).resolve(kits(errors))
      warn_unresolved(session, resolved, errors, on_event)
      resolved = nil if resolved.everything?
      tools = @tools.call
      return false if resolved == tools.toolkit

      tools.toolkit = resolved
      @reset_prompt.call
      true
    end

    private

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
  end
end
