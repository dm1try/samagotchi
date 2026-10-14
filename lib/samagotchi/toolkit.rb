# frozen_string_literal: true

require_relative "config"

module Samagotchi
  # A session's toolkit: which of the registered tools its prompts declare
  # (docs/sessions.md, "Toolkits"). Saved in the session file as given
  # ({"name" => "lean", "add" => [], "remove" => []}) when the session is
  # created, kept by continues and forks, and never resolved again from
  # config: a respawned worker declares what the session was created with.
  # A session without one (a file from before toolkits) is on FULL.
  #
  # +name+ names a Kit (the built-ins, config's toolkit.kits, a plugin's
  # chi.toolkit); +add+ and +remove+ are the session's own changes on top
  # (--tool / --no-tool, /toolkit add|remove). #resolve against the kits
  # known gives the Resolved the Registry filters by.
  Toolkit = Data.define(:name, :add, :remove) do
    def initialize(name:, add: [], remove: [])
      super(name: name.to_s.strip, add: Toolkit.tool_names(add), remove: Toolkit.tool_names(remove))
    end

    # @return [Hash] the session file's "toolkit"
    def to_file = { "name" => name, "add" => add, "remove" => remove }

    # The plain form the snapshot and the web carry.
    def to_h = { name: name, add: add, remove: remove }

    # This toolkit with +tool+ declared (/toolkit add): a tool it removed
    # comes out of +remove+ (back to its kit's), any other goes into +add+.
    def adding(tool)
      tool = tool.to_s
      remove.include?(tool) ? with(remove: remove - [tool]) : with(add: (add + [tool]).uniq)
    end

    # This toolkit with +tool+ left out (/toolkit remove), the other way.
    def removing(tool)
      tool = tool.to_s
      add.include?(tool) ? with(add: add - [tool]) : with(remove: (remove + [tool]).uniq)
    end

    # How the UIs name it: "lean", "lean +web_fetch -memory_write".
    def label = [name, *add.map { |tool| "+#{tool}" }, *remove.map { |tool| "-#{tool}" }].join(" ")

    def full? = name == Toolkit::FULL && add.empty? && remove.empty?

    # The kit +name+ names, from +kits+ (Toolkit.kits), with the session's
    # own +add+ and +remove+ on top. An unknown name, a base that is, or a
    # cycle falls back to FULL with the reason in Resolved#fallback; the
    # saved toolkit is untouched, so a reinstalled bundle gets it back.
    # @param kits [Hash{String => Kit}]
    # @return [Resolved]
    def resolve(kits)
      Toolkit.resolve_kit(name, kits).changed(add: add, remove: remove)
    rescue Toolkit::Unresolved => e
      Toolkit.resolve_kit(Toolkit::FULL, kits).changed(add: add, remove: remove).with(fallback: e.message)
    end
  end

  class Toolkit
    FULL = "full"
    LEAN = "lean"
    CHILD = "child"

    # A name that can't be resolved (unknown, a cycle).
    class Unresolved < StandardError; end

    # A toolkit as a session's next turn would declare it (Engine
    # #toolkit_explained): +toolkit+ as saved, +resolved+, the Registry
    # +declared+ entries and the names it leaves out (+left_out+), and
    # whether that isn't what the Registry declares now (+pending+: it
    # applies at the next turn's start).
    Explained = Data.define(:toolkit, :resolved, :declared, :left_out, :pending) do
      # What the prompt carries of it: the declared names and, when it
      # leaves tools out, the kit name the not-loaded line gives. Two equal
      # keys build the same prompt (/toolkit's "no change", its cost).
      def prompt_key = [declared.map(&:name), left_out.empty? ? nil : resolved.name]

      # What the UIs show (the snapshot, command_ran): nil when it declares
      # every tool on full (full, full +delegate), which has no chip.
      def summary
        return nil if toolkit.name == Toolkit::FULL && left_out.empty? && resolved.fallback.nil?

        { name: toolkit.name, label: toolkit.label, left_out: left_out, fallback: resolved.fallback }
      end
    end

    # Tool names as a list of unique, stripped strings.
    def self.tool_names(names) = Array(names).map { |tool| tool.to_s.strip }.reject(&:empty?).uniq

    # A named list of declared tools: +tools+ (:all, every built-in; or the
    # built-in names) when it has no +base+, else its +base+'s with +add+
    # and +remove+. +source+: "core", "config", or the bundle that declared
    # it (chi.toolkit).
    Kit = Data.define(:name, :base, :tools, :add, :remove, :source) do
      def initialize(name:, base: nil, tools: nil, add: [], remove: [], source: "core")
        super(name: name.to_s, base: base&.to_s, tools: tools == :all ? :all : Toolkit.tool_names(tools),
              add: Toolkit.tool_names(add), remove: Toolkit.tool_names(remove), source: source.to_s)
      end
    end

    # The built-ins `lean` declares: the file and shell tools, memories,
    # the task tools (execute's hand-over, turn notes and task_wait's tail
    # name the trio), questions, web_fetch, and context_read (core notes
    # tell the model to call it).
    LEAN_TOOLS = %w[
      execute read write edit memory_read memory_write task_create task_wait task_get task_list task_stop
      ask_user_question web_fetch context_read
    ].freeze

    BUILTIN_KITS = [
      Kit.new(name: FULL, tools: :all),
      Kit.new(name: LEAN, tools: LEAN_TOOLS),
      # A delegate child: it reports to its parent (send_note; the
      # delegated-by line names it) and leaves memory writes to it, and
      # starts no children of its own (removed: not even through call_tool).
      Kit.new(name: CHILD, base: LEAN, add: %w[send_note], remove: %w[memory_write delegate delegate_result])
    ].to_h { |kit| [kit.name, kit] }.freeze

    # What a toolkit declares, the Registry's filter: every built-in
    # (+all_core+) or the ones in +core+, every plugin tool and every tool
    # an LLM context layer gates (forget_outputs), but for +removed+;
    # +added+ declares any registered tool. +fallback+: why the session's
    # own toolkit couldn't be resolved (this is FULL then), nil when it was.
    Resolved = Data.define(:name, :all_core, :core, :added, :removed, :fallback) do
      def initialize(name:, all_core: false, core: [], added: [], removed: [], fallback: nil)
        super(name: name.to_s, all_core: all_core, core: core.dup.freeze, added: added.dup.freeze,
              removed: removed.dup.freeze, fallback: fallback)
      end

      # Every built-in and nothing removed: what no toolkit declares.
      def everything? = all_core && removed.empty?

      # @param entry [Tools::Registry::Entry]
      def declares?(entry)
        return false if removed.include?(entry.name)
        return true if added.include?(entry.name) || !entry.core? || !entry.layer.nil?

        all_core || core.include?(entry.name)
      end

      # This with +add+ declared and +remove+ left out, in that order of
      # the kit's own words: a later change wins.
      def changed(add: [], remove: [])
        added = self.added - remove
        removed = self.removed - add
        with(added: (added + add).uniq, removed: (removed + remove).uniq)
      end
    end

    # The session file's "toolkit": a Toolkit, nil for none (a file from
    # before toolkits, or one that isn't a toolkit), which reads as FULL.
    def self.from_file(value)
      case value
      when Hash
        name = value["name"] || value[:name]
        return nil if name.to_s.strip.empty?

        new(name: name, add: value["add"] || value[:add], remove: value["remove"] || value[:remove])
      when String, Symbol
        value.to_s.strip.empty? ? nil : new(name: value)
      end
    end

    # The toolkit a new session is stored on: config's toolkit.default, or
    # toolkit.child for a delegate child; FULL when unset. As named: the
    # worker resolves it (plugins' kits load there).
    def self.configured(delegate: false)
      name = Config.get(delegate ? "toolkit.child" : "toolkit.default").to_s.strip
      new(name: name.empty? ? FULL : name)
    end

    # config.yml's toolkit.kits (a map of name => {base:, add:, remove:}),
    # nil when it has none.
    def self.config_kits
      section = ConfigFile.section("toolkit")
      section.is_a?(Hash) ? section["kits"] : nil
    rescue StandardError
      nil
    end

    # A new session's toolkit from chi --toolkit NAME / --tool / --no-tool
    # (each repeatable, a comma list too): NAME (config's toolkit.default
    # without one) with those tools added and left out; nil when none was
    # given. A tool in both is left out.
    def self.from_flags(name: nil, add: [], remove: [])
      add = split_names(add)
      remove = split_names(remove)
      return nil if name.to_s.strip.empty? && add.empty? && remove.empty?

      base = name.to_s.strip.empty? ? configured.name : name
      new(name: base, add: add - remove, remove: remove)
    end

    def self.split_names(values) = tool_names(Array(values).flat_map { |value| value.to_s.split(",") })
    private_class_method :split_names

    # The toolkit a session is on: its own, or FULL without one.
    def self.of(toolkit) = toolkit || new(name: FULL)

    # What a toolkit change costs the prompt cache (CacheConfirm): the
    # declared tools are the front of every request, so any change to them
    # (or to the not-loaded line) is :full; nil when they stay the same.
    # @param before [Object] what the prompt carries now (Explained#prompt_key)
    # @param after [Object] what it would carry after the change
    def self.cache_cost(before, after) = before == after ? nil : :full

    # @return [Resolved] +name+'s kit through its bases
    # @raise [Unresolved] unknown, or a cycle
    def self.resolve_kit(name, kits, seen = [])
      raise Unresolved, "no toolkit named #{name}" unless (kit = kits[name])
      raise Unresolved, "toolkit #{name}'s bases make a cycle (#{(seen + [name]).join(" → ")})" if seen.include?(name)

      base = if kit.base
               resolve_kit(kit.base, kits, seen + [name])
             else
               Resolved.new(name: name, all_core: kit.tools == :all, core: kit.tools == :all ? [] : kit.tools)
             end
      base.changed(add: kit.add, remove: kit.remove).with(name: name)
    end

    # The kits known: the built-ins, then config's toolkit.kits, then the
    # plugins' (chi.toolkit). A config kit with a built-in's name is left
    # out (one it can't redefine) with a line in +errors+, and so is one
    # that isn't a {base:, add:, remove:} map.
    # @param config [Hash, nil] toolkit.kits
    # @param plugins [Array<Kit>]
    # @param errors [Array<String>] gets a line per kit left out
    # @return [Hash{String => Kit}]
    def self.kits(config: nil, plugins: [], errors: [])
      kits = BUILTIN_KITS.dup
      (config.is_a?(Hash) ? config : {}).each do |name, spec|
        name = name.to_s
        if kits.key?(name)
          errors << "toolkit.kits.#{name}: #{name} is a built-in toolkit"
        elsif !spec.is_a?(Hash)
          errors << "toolkit.kits.#{name}: expected {base:, add:, remove:}"
        else
          spec = spec.transform_keys(&:to_s)
          kits[name] = Kit.new(name: name, base: spec["base"] || FULL, add: spec["add"], remove: spec["remove"],
                               source: "config")
        end
      end
      plugins.each { |kit| kits[kit.name] ||= kit }
      kits
    end
  end
end
