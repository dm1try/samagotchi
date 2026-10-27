# frozen_string_literal: true

require_relative "config"
require_relative "model_match"

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

    # This toolkit with +tool+ declared (/toolkit add): out of +remove+
    # and into +add+, whatever its kit says (an add after a remove
    # declares it).
    def adding(tool)
      tool = tool.to_s
      with(remove: remove - [tool], add: (add + [tool]).uniq)
    end

    # This toolkit with +tool+ removed (/toolkit remove), the other way: a
    # remove is hard (call_tool can't reach it either), also after an add.
    def removing(tool)
      tool = tool.to_s
      with(add: add - [tool], remove: (remove + [tool]).uniq)
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
    # A participant's turn (Guardrails::ReviewBoundary): the name is
    # reserved, so config and plugins can't redefine the boundary.
    REVIEW = "review"

    # A name that can't be resolved (unknown, a cycle).
    class Unresolved < StandardError; end

    # A toolkit as a session's next turn would declare it (Engine
    # #toolkit_explained): +toolkit+ as saved, +resolved+, the Registry
    # +declared+ entries and the names it leaves out (+left_out+): the ones
    # call_tool reaches (+reachable+) and the ones it removes (+removed+);
    # and whether that isn't what the Registry declares now (+pending+: it
    # applies at the next turn's start).
    Explained = Data.define(:toolkit, :resolved, :declared, :left_out, :reachable, :removed, :pending) do
      def initialize(toolkit:, resolved:, declared:, left_out:, pending:, reachable: [], removed: [])
        super
      end

      # What the prompt carries before the kit's prompt text: the declared
      # names, reachable and removed ones (the not-loaded line, find_tools'
      # chi line), and, when either list has any, the kit name the line gives.
      def tools_key
        [declared.map(&:name), reachable, removed, resolved.groups,
         reachable.empty? && removed.empty? ? nil : resolved.name]
      end

      # What the prompt carries of it, including the kit's prompt text. Two
      # equal keys build the same prompt (/toolkit's "no change", its cost).
      def prompt_key = [*tools_key, resolved.prompt]

      # What the UIs show (the snapshot, command_ran): nil when it declares
      #   every tool on full (full, full +delegate), which has no chip unless
      #   its groups are filtered.
      # +left_out+ is +reachable+ and +removed+ together; +prompt+ (the
      # kit's text) only when the kit has one.
      def summary
        return nil if toolkit.name == Toolkit::FULL && left_out.empty? && resolved.fallback.nil? &&
                      resolved.groups == :all

        summary = { name: toolkit.name, label: toolkit.label, left_out: left_out, reachable: reachable,
                    removed: removed, fallback: resolved.fallback, groups: resolved.groups }
        resolved.prompt ? summary.merge(prompt: resolved.prompt) : summary
      end
    end

    # Tool names as a list of unique, stripped strings.
    def self.tool_names(names) = Array(names).map { |tool| tool.to_s.strip }.reject(&:empty?).uniq

    # Group names/globs as a stable list, or :all. Selectors match against
    # the source's declaration-time group snapshot.
    def self.group_names(groups)
      return :all if groups == :all

      Array(groups).map { |group| group.to_s.strip }.reject(&:empty?).uniq.sort.freeze
    end

    # Whether a source group +name+ is one of +selectors+: fnmatch globs in
    # the guardrails rules' grammar (ModelMatch::GLOB_FLAGS: any case,
    # extglob), so `groups: [Chrome]` reaches chrome.
    def self.group_matches?(selectors, name)
      selectors == :all || selectors.any? { |selector| File.fnmatch?(selector, name.to_s, ModelMatch::GLOB_FLAGS) }
    end

    # Why +value+ can't be a kit's groups (a group name or glob, or a list
    # of them), nil when it can (nil too: its base's groups).
    def self.groups_error(value)
      return nil if value.nil? || value.is_a?(String)
      return nil if value.is_a?(Array) && value.all? { |group| group.is_a?(String) || group.is_a?(Symbol) || group.is_a?(Numeric) }

      "groups must be a list of group names or globs"
    end

    # config.yml's toolkit.kits.NAME line for a +value+ that can't be its
    # groups (groups_error), nil when it can: the one wording a worker's
    # warning and a creation's refusal both start with.
    def self.config_groups_error(name, value)
      problem = groups_error(value)
      problem && "toolkit.kits.#{name}: #{problem}"
    end

    # A new session refused: its toolkit, or a base it builds on, is a
    # config.yml kit (toolkit.kits) whose groups: isn't a name or a list of
    # them. A session never starts on a reach other than the one written
    # (its base's groups: wider or narrower); the message is the one line
    # every creation surface shows.
    class Refused < StandardError
      # @param toolkit [String] the new session's toolkit name
      # @param problem [String] config_groups_error's line
      def self.for(toolkit, problem) = new("#{problem}; fix config.yml to start a session on toolkit #{toolkit}")
    end

    # Raises Refused when +toolkit+ (a new session's: Session.new_session)
    # names a config kit, or builds on one through its bases, whose
    # groups: is invalid (config_groups_error). Only config.yml's kits are
    # followed: a bundle's (chi.toolkit) refuses at its load, and a name
    # that doesn't resolve stays the worker's warning.
    # @param config [Hash, nil] toolkit.kits (config.yml's by default)
    # @return [Toolkit] +toolkit+
    # @raise [Refused]
    def self.check_new!(toolkit, config: config_kits)
      return toolkit unless toolkit && config.is_a?(Hash)

      name = toolkit.name
      seen = []
      until seen.include?(name) || name == REVIEW || BUILTIN_KITS.key?(name)
        seen << name
        spec = config[name] || config[name.to_sym]
        break unless spec.is_a?(Hash)

        spec = spec.transform_keys(&:to_s)
        problem = config_groups_error(name, spec["groups"])
        raise Refused.for(toolkit.name, problem) if problem

        name = (spec["base"] || FULL).to_s
      end
      toolkit
    end

    # A named list of declared tools: +tools+ (:all, every built-in; or the
    # built-in names) when it has no +base+, else its +base+'s with +add+
    # and +remove+. +source+: "core", "config", or the bundle that declared
    # it (chi.toolkit). +prompt+: text the sessions on it get in their
    # system prompt, verbatim (stripped); nil inherits the base's, "" clears
    #   it. +groups+: :all or a sorted list of source group names/globs; nil
    #   inherits the base's.
    #   +description+: optional classifier text; it is not prompt text.
    Kit = Data.define(:name, :base, :tools, :add, :remove, :source, :prompt, :groups, :description) do
      def initialize(name:, base: nil, tools: nil, add: [], remove: [], source: "core", prompt: nil, groups: nil,
                     description: nil)
        super(name: name.to_s, base: base&.to_s, tools: tools == :all ? :all : Toolkit.tool_names(tools),
              add: Toolkit.tool_names(add), remove: Toolkit.tool_names(remove), source: source.to_s,
              prompt: prompt.is_a?(String) ? prompt.strip.freeze : nil,
              groups: groups.nil? ? nil : Toolkit.group_names(groups),
              description: description.is_a?(String) ? description.strip.freeze : nil)
      end
    end

    # The longest kit prompt, in characters: it is a cached prefix, not a
    # document (long text belongs in append_system_prompt:).
    PROMPT_MAX = 2000

    # Why +value+ can't be a kit's prompt (text, at most PROMPT_MAX
    # characters once stripped), nil when it can (nil too: no prompt).
    def self.prompt_error(value)
      return nil if value.nil?
      return "prompt must be text" unless value.is_a?(String)

      "prompt is over #{PROMPT_MAX} characters" if value.strip.length > PROMPT_MAX
    end

    DESCRIPTION_MAX = 300

    # Why +value+ can't describe a kit (text, at most DESCRIPTION_MAX
    # characters once stripped), nil when it can (nil too: no description).
    def self.description_error(value)
      return nil if value.nil?
      return "description must be text" unless value.is_a?(String)

      "description is over #{DESCRIPTION_MAX} characters" if value.strip.length > DESCRIPTION_MAX
    end

    # The built-ins `lean` declares: the file and shell tools, memories,
    # the task tools (execute's hand-over, turn notes and task_wait's tail
    # name the trio), questions, web_fetch, and context_read (core notes
    # tell the model to call it).
    LEAN_TOOLS = %w[
      execute read write edit memory_read memory_write task_create task_wait task_get task_list task_stop
      ask_user_question web_fetch context_read
    ].freeze

    # The built-ins a participant's turn may call (REVIEW): reads only.
    # ReviewBoundary denies everything else, whatever the session declares
    # (D3: the declared tools stay the session's), the forget layer's
    # forget_outputs too (a layer tool, declared with every kit).
    REVIEW_TOOLS = %w[read memory_read].freeze

    BUILTIN_KITS = [
      Kit.new(name: FULL, tools: :all, groups: :all),
      Kit.new(name: LEAN, tools: LEAN_TOOLS, groups: :all),
      # A delegate child: it reports to its parent (send_note; the
      # delegated-by line names it) and leaves memory writes to it, and
      # starts no children of its own (removed: not even through call_tool).
      Kit.new(name: CHILD, base: LEAN, add: %w[send_note], remove: %w[memory_write delegate delegate_result]),
      Kit.new(name: REVIEW, tools: REVIEW_TOOLS, groups: [])
    ].to_h { |kit| [kit.name, kit] }.freeze

    # What a toolkit declares, the Registry's filter: every built-in
    # (+all_core+) or the ones in +core+, every plugin tool and every tool
    # an LLM context layer gates (forget_outputs), but for +removed+;
    # +added+ declares any registered tool. +fallback+: why the session's
    # own toolkit couldn't be resolved (this is FULL then), nil when it was.
    # +prompt+: the kit's prompt text (its own or its base's), nil without.
    # +groups+: :all or the sorted source group names/globs it reaches.
    Resolved = Data.define(:name, :all_core, :core, :added, :removed, :fallback, :prompt, :groups) do
      def initialize(name:, all_core: false, core: [], added: [], removed: [], fallback: nil, prompt: nil, groups: :all)
        super(name: name.to_s, all_core: all_core, core: core.dup.freeze, added: added.dup.freeze,
              removed: removed.dup.freeze, fallback: fallback, prompt: prompt, groups: Toolkit.group_names(groups))
      end

      # Whether a declared source group is reached by this toolkit.
      def reaches_group?(name) = Toolkit.group_matches?(groups, name)

      # Every built-in, nothing removed, no prompt text and no group filter:
      # what no toolkit declares (the Registry's nil).
      def everything? = all_core && removed.empty? && prompt.nil? && groups == :all

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

    # config.yml's toolkit.kits (a map of name => {base:, add:, remove:, groups:}),
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

    # @return [Resolved] +name+'s kit through its bases; its prompt is the
    #   kit's own, else its base's ("" clears it: nil)
    # @raise [Unresolved] unknown, or a cycle
    def self.resolve_kit(name, kits, seen = [])
      raise Unresolved, "no toolkit named #{name}" unless (kit = kits[name])
      raise Unresolved, "toolkit #{name}'s bases make a cycle (#{(seen + [name]).join(" → ")})" if seen.include?(name)

      base = if kit.base
               resolve_kit(kit.base, kits, seen + [name])
             else
               Resolved.new(name: name, all_core: kit.tools == :all, core: kit.tools == :all ? [] : kit.tools,
                            groups: kit.groups || :all)
             end
      prompt = kit.prompt.nil? ? base.prompt : kit.prompt
      groups = kit.groups.nil? ? base.groups : kit.groups
      base.changed(add: kit.add, remove: kit.remove)
          .with(name: name, prompt: prompt.to_s.empty? ? nil : prompt, groups: groups)
    end

    # config.yml's toolkit.kits.review, refused: the review kit is the
    # participants' boundary, which config may not widen.
    RESERVED_REVIEW = "toolkit.kits.review: review is reserved for participants' turns (chi share); " \
                      "name your kit something else"

    # The keys a config kit entry takes.
    KIT_KEYS = %w[base add remove prompt groups description].freeze

    # The kits known: the built-ins, then config's toolkit.kits, then the
    # plugins' (chi.toolkit). A config kit with a built-in's name is left
    # out (one it can't redefine; review, the participants' boundary, is
    # reserved) with a line in +errors+, and so is one
    #   that isn't a {base:, add:, remove:, prompt:, groups:, description:} map. One with another key
    # (a typo, a tools: list) still loads, with a line naming the key, and
    # so does one whose prompt isn't text or is over PROMPT_MAX characters:
    # without the prompt, with a line saying why. One whose groups: isn't
    # a name or a list (config_groups_error) loads reaching no group, with
    # a line: a session saved on it before the typo (no new one starts on
    # it: check_new!) never reaches wider than written.
    # @param config [Hash, nil] toolkit.kits
    # @param plugins [Array<Kit>]
    # @param errors [Array<String>] gets a line per kit left out or unknown key
    # @return [Hash{String => Kit}]
    def self.kits(config: nil, plugins: [], errors: [])
      kits = BUILTIN_KITS.dup
      (config.is_a?(Hash) ? config : {}).each do |name, spec|
        name = name.to_s
        if name == REVIEW
          errors << RESERVED_REVIEW
        elsif kits.key?(name)
          errors << "toolkit.kits.#{name}: #{name} is a built-in toolkit"
        elsif !spec.is_a?(Hash)
          errors << "toolkit.kits.#{name}: expected {base:, add:, remove:, prompt:, groups:, description:}"
        else
          spec = spec.transform_keys(&:to_s)
          (spec.keys - KIT_KEYS).each do |key|
            errors << "toolkit.kits.#{name}: unknown key #{key} " \
                      "(a kit takes base:, add:, remove:, prompt:, groups:, description:)"
          end
          if (problem = prompt_error(spec["prompt"]))
            errors << "toolkit.kits.#{name}: #{problem}; the kit loads without it"
            spec.delete("prompt")
          end
          if (problem = description_error(spec["description"]))
            errors << "toolkit.kits.#{name}: #{problem}; the kit loads without it"
            spec.delete("description")
          end
          if (problem = config_groups_error(name, spec["groups"]))
            errors << "#{problem}; the kit reaches no tool-index group until it is fixed"
            spec["groups"] = []
          end
          kits[name] = Kit.new(name: name, base: spec["base"] || FULL, add: spec["add"], remove: spec["remove"],
                               prompt: spec["prompt"], groups: spec["groups"], source: "config",
                               description: spec["description"])
        end
      end
      plugins.each { |kit| kits[kit.name] ||= kit }
      kits
    end
  end
end
