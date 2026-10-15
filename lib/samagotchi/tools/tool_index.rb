# frozen_string_literal: true

require "json"
require_relative "args"
require_relative "builtin_calls"
require_relative "registry"
require_relative "../log"
require_relative "../token_usage"
require_relative "../tool_declarations"
require_relative "../plugin/tool_spec"

module Samagotchi
  module Tools
    # The tools a session knows but doesn't declare one by one, and the two
    # tools that reach them (docs/plugins.md, "Publishing tools to the
    # index"): find_tools, a keyword search that answers each match's
    # inputSchema, and call_tool, which calls one as <group>/<tool>.
    # A source (the mcp bundle, chi.tool_source) publishes its groups (an
    # MCP server each) and runs the calls; the index's own group, chi, is
    # the built-ins the session's toolkit leaves out but doesn't remove
    # (Registry#reachable_names), and a call_tool of one runs as that
    # built-in (#unwrap, before the guardrail gate). The index searches the
    # groups, looks a call's tool up and checks it.
    #
    # The two tools are registered once, after the plugins load, and
    # declared per toolkit (Registry#declared?): when a source registered
    # then, or the toolkit leaves a built-in reachable. The search tool's
    # description has the source groups' lines as they were at load and a
    # chi line per toolkit (#refresh!): nothing a source publishes later
    # changes the request's tools, so the prompt cache keeps.
    #
    # They are registry entries of source SOURCE, not "core": a plugin
    # tool's paths (guardrail targets, the row's label and preview, native
    # flat schemas) are the ones call_tool has always had.
    class ToolIndex
      SOURCE = "index"
      FIND_NAME = "find_tools"
      # What an unwrapped call carries as via: too.
      CALL_NAME = BuiltinCalls::VIA
      # Matches a search answers, and names a miss suggests.
      FIND_RESULTS = 5
      CLOSEST = 3
      # A query word in a tool's name (or its group's) counts this many
      # times one in its description.
      NAME_WEIGHT = 3
      PREVIEW_CHARS = 60
      # The index's own group: chi's built-ins a toolkit leaves out.
      CHI_GROUP = "chi"
      CHI_SUMMARY = "chi's own tools not declared in this session"
      # Group names a source can't publish: the index's own groups'.
      RESERVED_GROUPS = [CHI_GROUP].freeze

      FIND_PARAMS = {
        query: { type: "string", required: true,
                 description: "keywords for what the tool does (\"screenshot page\"); empty lists every tool's name" },
        group: { type: "string", description: "search only this group" }
      }.freeze
      CALL_DESCRIPTION = "Call a tool #{FIND_NAME} found.".freeze
      CALL_PARAMS = {
        tool: { type: "string", required: true, description: "the tool as <group>/<tool>" },
        args: { type: "object", description: "the arguments, per the inputSchema #{FIND_NAME} gave" }
      }.freeze

      # One tool in the index: +group+/+name+ is what the call tool takes,
      # +schema+ its inputSchema, +acts_as+ the name guardrail rules match
      # (mcp_<server>_<tool>; a bare name the call tool looks up too).
      # +refusal+ is why it can't be called (nil when it can), +mark+ what a
      # search shows beside its name then ("(bad schema)"). +entry+ is the
      # Registry entry of a tool the index's own groups list (nil for a
      # source's). A blank +acts_as+ raises ArgumentError: no rule could
      # match the tool's calls.
      Tool = Data.define(:group, :name, :description, :schema, :acts_as, :refusal, :mark, :entry) do
        def initialize(group:, name:, acts_as:, description: "", schema: nil, refusal: nil, mark: nil, entry: nil)
          raise ArgumentError, "tool #{group}/#{name}: acts_as is blank" if acts_as.to_s.strip.empty?

          super(group: group.to_s, name: name.to_s, description: description.to_s,
                schema: schema || { "type" => "object", "properties" => {} }, acts_as: acts_as.to_s,
                refusal: refusal, mark: mark, entry: entry)
        end

        def full_name = "#{group}/#{name}"
      end

      # A Group's states.
      STATES = %i[ready starting failed].freeze

      # One group of a source's tools (an MCP server): +summary+ its line in
      # the search tool's description (nil: its name and tool count only),
      # +state+ :ready, :starting (its tools may come: a lookup waits) or
      # :failed (+error+ says why). A group exists before its tools do.
      # Another state, or a tool of another group, raises ArgumentError (a
      # lookup would neither wait on it nor find the tool's source).
      Group = Data.define(:name, :summary, :state, :error, :tools) do
        def initialize(name:, summary: nil, state: :ready, error: nil, tools: [])
          raise ArgumentError, "group #{name}: state must be one of #{STATES.join(", ")}" unless STATES.include?(state)

          tools = Array(tools)
          raise ArgumentError, "group #{name}: tools must be ToolIndex::Tool values" unless tools.all?(Tool)
          if (stray = tools.find { |tool| tool.group != name.to_s })
            raise ArgumentError, "group #{name}: tool #{stray.full_name} belongs to group #{stray.group}"
          end

          summary = summary.to_s.strip
          super(name: name.to_s, summary: summary.empty? ? nil : summary, state: state, error: error,
                tools: tools.dup.freeze)
        end

        # The tools the call tool can call.
        def callable = tools.reject(&:refusal)

        # What a search says about a group whose tools can't be called now.
        def note
          case state
          when :failed then "(failed: #{error})"
          when :starting then "(starting, try again)"
          end
        end
      end

      # What a source (a plugin, chi.tool_source) holds: its groups, which
      # #publish swaps in whole, and how its calls run. Its hooks: +call+
      # (tool, args, ctx) runs a checked call (args typed by the tool's
      # schema; ctx the plugin's Context) and returns its result; +wait+
      # (group) waits for a :starting group's start; +acts_as+ (group, tool)
      # names a tool guardrails see from the names alone (one not listed
      # yet). +prefix+: a bare name with it is taken as an acts_as as given.
      # +label+ is the call tool's row label.
      class Source
        attr_reader :label, :prefix, :context, :groups, :declared_names, :declared_tokens

        def initialize(label:, call:, acts_as:, wait: nil, prefix: nil, context: nil)
          raise ArgumentError, "tool_source: call must respond to #call" unless call.respond_to?(:call)
          raise ArgumentError, "tool_source: acts_as must respond to #call" unless acts_as.respond_to?(:call)
          raise ArgumentError, "tool_source: wait must respond to #call" if wait && !wait.respond_to?(:call)

          @label = label.to_s
          @call = call
          @acts_as = acts_as
          @wait = wait
          @prefix = prefix&.to_s
          @context = context
          @groups = [].freeze
          @declared_names = []
          @declared_tokens = 0
        end

        def inspect = "#<ToolIndex::Source #{@label} groups=#{@groups.map(&:name).join(",")}>"

        # Make +groups+ the source's: one swap, so a search on another
        # thread sees the old list or the new one, never half.
        # @param groups [Array<Group>]
        def publish(groups)
          groups = Array(groups)
          raise ArgumentError, "publish takes ToolIndex::Group values" unless groups.all?(Group)

          @groups = groups.dup.freeze
          nil
        end

        def run(tool, args) = @call.call(tool, args, @context)

        def wait(group)
          @wait&.call(group)
        rescue StandardError
          nil
        end

        def acts_as(group, tool) = @acts_as.call(group, tool).to_s

        # What ToolIndex#declare registered: the tools' names and their
        # definitions' estimated tokens (the mcp bundle's /mcp says them).
        def declared!(names, tokens)
          @declared_names = names.dup.freeze
          @declared_tokens = tokens
        end
      end

      def initialize
        @sources = []
        # The Registry #declare registered in: the chi group reads it.
        @registry = nil
        # The source groups' lines in the search tool's description, as
        # #declare found them (#find_description).
        @described = [].freeze
        @dropped = []
        @dropped_mutex = Mutex.new
      end

      # A new source, not in the index yet (Plugin::Api#commit! #add's it).
      def source(**) = Source.new(**)

      def add(source)
        @sources << source
        nil
      end

      def sources = @sources.dup

      # Every group, now: the index's own (#registry_groups), then the
      # sources'. A source group with a reserved name, or one an earlier
      # group has, is left out of search, lookup and the description (said
      # once per name: a source publishes after load too).
      def groups
        own = registry_groups
        taken = own.map(&:name) | RESERVED_GROUPS
        kept = @sources.flat_map(&:groups).select do |group|
          why = if RESERVED_GROUPS.include?(group.name) then "reserved"
                elsif taken.include?(group.name) then "taken by another group"
                end
          dropped(group.name, why) if why
          taken << group.name unless why
          why.nil?
        end
        own + kept
      end

      # Register the search and call tools in +registry+, once, after the
      # plugins load (or without them: the built-ins a toolkit leaves out
      # are reachable either way); +registry+ declares them per toolkit
      # (Registry::Index). A name another tool has is left out (a line in
      # +failures+).
      # @return [Array<String>] the names registered
      def declare(registry, failures: nil)
        @registry = registry
        @described = description_lines(groups.reject { |group| own?(group) }).freeze
        specs = [find_spec, call_spec]
        declared = specs.filter_map do |spec|
          if (taken = registry[spec.name])
            failures&.add("tool #{spec.name}", "already registered (#{taken.source}); the tool index's is left out",
                          required: false)
            next
          end

          unwrap = (->(call, layers) { unwrap(call, layers) } if spec.name == CALL_NAME)
          registry.register(spec.name, source: SOURCE, unwrap: unwrap, **spec.entry_fields(nil))
          spec
        end
        registry.index = Registry::Index.new(source: SOURCE, call_name: CALL_NAME, sourced: !@sources.empty?)
        declared!(declared)
        declared.map(&:name)
      end

      # The search tool's description again for the Registry's toolkit now
      # (ToolkitBinding#apply!, at a turn's start): its chi line follows the
      # toolkit, the source groups' are the ones #declare found.
      def refresh!
        entry = @registry && @registry[FIND_NAME]
        return unless entry&.source == SOURCE

        entry.schema = entry.schema.merge(description: find_description)
        declared!([find_spec, call_spec].select { |spec| @registry[spec.name]&.source == SOURCE })
      end

      # A checked tool declaration's (Plugin::ToolSpec) definition as
      # the chat path sends it (LLM::ChatLoop#tool_definitions: the chat
      # schema, wrapped as a function), in estimated tokens
      # (TokenUsage::CHARS_PER_TOKEN). The native prompts (Gemma, Qwen)
      # render a flatter schema, so it is an upper bound there.
      def self.spec_tokens(spec)
        function = ToolDeclarations.chat_schemas([spec.schema]).first.slice(:name, :description, :parameters)
        TokenUsage.estimate(JSON.generate({ type: "function", function: function }))
      end

      # Appended to a failure the arguments may cause: the tool's
      # inputSchema, so the next call can fix them (a call guessed without
      # a search).
      def self.schema_note(tool)
        "\n\n#{tool.full_name}'s inputSchema: #{JSON.generate(tool.schema)}"
      end

      # The search tool's description: how to use it, and one line per
      # group from what was known when it was declared (a first-run
      # server's: its name, and its summary if it has one). Never every
      # tool: knowing the names, a model searches less and guesses
      # arguments.
      def find_description
        "Search tools this session doesn't declare, by keywords. It answers up to #{FIND_RESULTS} tools, each with " \
          "its name (<group>/<tool>) and inputSchema; call one with #{CALL_NAME}. An empty query lists every tool's " \
          "name.\nGroups:\n#{(description_lines(registry_groups) + @described).join("\n")}"
      end

      # ── Search ──────────────────────────────────────────────────────────

      # The search tool: the best matches with their schemas, or with an
      # empty query every group's tool names. +server+ is the parameter's
      # name before it was +group+: a model that still gives it is told
      # every group was searched.
      def find(query, only = nil, server: nil)
        answer = find_in(query, only)
        return answer unless (only.nil? || only.strip.empty?) && !server.to_s.strip.empty?

        "(searched every group)\n#{answer}"
      end

      # ── The call ────────────────────────────────────────────────────────

      # A call of the tool +name+ names, with +args+ typed by its schema,
      # run by its source. It fails closed: a tool that isn't the one
      # guardrails were given (#claimed) is refused, and so is one of the
      # index's own (a built-in runs as itself, #unwrap, or not at all).
      def call(name, args)
        tool = lookup(name)
        return tool if tool.is_a?(String)

        unless claimed(name.strip)&.first == tool.acts_as
          # A bare acts_as of a source with no prefix: guardrails can't
          # name it before its tool is listed (#claimed), so only
          # <group>/<tool> is taken.
          return "Error: call #{name.strip} as #{tool.full_name}" if name.strip == tool.acts_as

          return "Error: the tool list changed while the call waited for its server; call #{tool.full_name} again"
        end
        return "Error: #{tool.full_name} can't be called: #{tool.refusal}" if tool.refusal

        inner = inner_args(args, tool)
        return "Error: args must be an object.#{ToolIndex.schema_note(tool)}" unless inner
        return "Error: #{tool.full_name} can't be called through #{CALL_NAME} here" if tool.entry

        # A publish may drop the group after the lookup.
        source = source_of(tool.group)
        return "Error: the tool list changed and #{tool.group} is gone; search with #{FIND_NAME}" unless source

        source.run(tool, inner)
      end

      # The built-in a call_tool +call+ names, as the call that runs in its
      # place (ToolRunner#run's first step, before the guardrail gate):
      # built from its arguments as a direct call would be
      # (BuiltinCalls.build), with via: "call_tool". The name is a chi tool
      # (a bare one only while the toolkit reaches it), or chi/<built-in>
      # for any registered built-in: one the toolkit removes or declares
      # is then refused by its name before the gate (ToolRunner#left_out?),
      # with no hook or card. Nil, so the call runs as call_tool, when the
      # turn under +layers+ doesn't offer call_tool, for an MCP tool, a miss
      # or arguments that aren't an object.
      # @return [Hash, nil]
      def unwrap(call, layers = [])
        return nil unless @registry&.offered(CALL_NAME, layers: layers)

        args = call[:args].is_a?(Hash) ? call[:args] : {}
        name = args["tool"].to_s.strip
        tool = lookup_quietly(name)
        entry = tool&.entry || builtin_named(name)
        return nil unless entry

        inner = inner_args(args["args"], tool)
        inner && BuiltinCalls.build(entry.name, inner).merge(via: CALL_NAME)
      end

      # The call tool's activity row: <group>/<tool> and its arguments.
      def call_preview(args)
        tool = lookup_quietly(args["tool"].to_s)
        name = tool ? tool.full_name : args["tool"].to_s.strip
        inner = tool && inner_args(args["args"], tool)
        inner ? [name, preview(inner)].reject(&:empty?).join(" ") : name
      end

      # What guardrail rules match a call: the tool it calls, by its
      # acts_as, its arguments, and the question's label. A tool not
      # indexed yet (its server still starting) is named from what the
      # model gave (#claimed), so a rule on it fires before the call waits
      # for the server. Nothing for a name that can't be a tool (the call
      # refuses it).
      def call_targets(args)
        name = args["tool"].to_s.strip
        tool = lookup_quietly(name)
        acts_as, label = tool ? [tool.acts_as, "#{tool.group}: #{tool.name}"] : claimed(name)
        return {} unless acts_as

        { acts_as: acts_as, args: inner_args(args["args"], tool) || {}, label: label }.compact
      end

      private

      def find_spec
        Plugin::ToolSpec.build(FIND_NAME, find_description, params: FIND_PARAMS,
                                                           preview: lambda { |args|
                                                             [args["query"].to_s.strip, args["group"] && "in #{args["group"]}"].compact.join(" ")
                                                           }) do |args, _ctx|
          find(args["query"].to_s, args["group"], server: args["server"])
        end
      end

      def call_spec
        Plugin::ToolSpec.build(CALL_NAME, CALL_DESCRIPTION, params: CALL_PARAMS, label: @sources.first&.label,
                                                           preview: ->(args) { call_preview(args) },
                                                           targets: ->(args) { call_targets(args) }) do |args, _ctx|
          call(args["tool"].to_s, args["args"])
        end
      end

      # The source whose group +group+ is: nil for the index's own (a
      # reserved name).
      def source_of(group)
        return nil if RESERVED_GROUPS.include?(group)

        @sources.find { |source| source.groups.any? { |g| g.name == group } }
      end

      def find_in(query, only)
        all = groups
        searched = all
        if only && !only.strip.empty?
          searched = all.select { |group| group.name == only.strip }
          return "Error: no group #{only.strip}. Groups: #{all.map(&:name).join(", ")}" if searched.empty?
        end
        return names_text(searched) if words(query).empty?

        matches = ranked(query, searched.flat_map(&:tools)).take(FIND_RESULTS)
        return "No tool matches \"#{query.strip}\".\n\n#{names_text(searched)}" if matches.empty?

        blocks = matches.map { |tool| match_text(tool, all) }
        unsearched = searched.filter_map { |group| "#{group.name} #{group.note}" if group.tools.empty? && group.note }
        blocks << "Not searched: #{unsearched.join("; ")}." unless unsearched.empty?
        "Call one with #{CALL_NAME}(tool: \"<group>/<tool>\", args: {…}).\n\n#{blocks.join("\n\n")}"
      end

      # What the sources hear of the declared tools (/mcp's last line).
      def declared!(specs)
        names = specs.map(&:name)
        tokens = specs.sum { |spec| ToolIndex.spec_tokens(spec) }
        @sources.each { |source| source.declared!(names, tokens) }
      end

      def own?(group) = RESERVED_GROUPS.include?(group.name)

      # The registered built-in chi/<name> names, reachable or not.
      def builtin_named(name)
        return nil unless name.start_with?("#{CHI_GROUP}/")

        entry = @registry[name.delete_prefix("#{CHI_GROUP}/")]
        entry if entry&.core?
      end

      # The index's own groups: chi, the built-ins the Registry's toolkit
      # leaves out but reaches (none: no group). Each tool's schema is its
      # registered entry's (a config's execute description included), and
      # it acts as itself.
      # @return [Array<Group>]
      def registry_groups
        names = @registry ? @registry.reachable_names : []
        return [] if names.empty?

        tools = names.map do |name|
          entry = @registry[name]
          schema = ToolDeclarations.chat_schemas([entry.schema]).first
          Tool.new(group: CHI_GROUP, name: name, acts_as: name, description: schema[:description].to_s,
                   schema: JSON.parse(JSON.generate(schema[:parameters])), entry: entry)
        end
        [Group.new(name: CHI_GROUP, summary: CHI_SUMMARY, tools: tools)]
      end

      # One line per group in the search tool's description: its name, its
      # summary and how many tools it can call.
      def description_lines(groups)
        groups.map do |group|
          count = group.callable.size
          line = "- #{group.name}"
          line += ": #{group.summary}" if group.summary
          line += " (#{count} tool#{"s" unless count == 1})" unless group.tools.empty?
          line
        end
      end

      # Say once per name that a source's group was left out (#groups).
      def dropped(name, why)
        first = @dropped_mutex.synchronize { @dropped.include?(name) ? false : (@dropped << name) }
        return unless first

        Log.warn(:plugins, "tool_group_dropped", group: name, why: why,
                                                 msg: "tool group #{name} is left out of the tool index: #{why}")
      end

      # One match: its name, why it can't be called (if so), its
      # description and schema.
      def match_text(tool, all)
        group = all.find { |g| g.name == tool.group }
        head = [tool.full_name, tool.mark, group&.note].compact.join(" ")
        return "#{head}: #{tool.description}\nIt can't be called: #{tool.refusal}" if tool.refusal

        "#{head}: #{tool.description}\ninputSchema: #{JSON.generate(tool.schema)}"
      end

      # Each group's tool names, one line each.
      def names_text(groups)
        lines = groups.map do |group|
          names = group.tools.map { |tool| [tool.name, tool.mark].compact.join(" ") }
          head = [group.name, group.note].compact.join(" ")
          names.empty? ? head : "#{head}: #{names.join(", ")}"
        end
        "Tools by group (call one as <group>/<tool>; search for its inputSchema):\n#{lines.join("\n")}"
      end

      # +tools+ that share a word with +query+, best first: a word scores
      # its IDF over +tools+ (a word most of them have counts little), times
      # NAME_WEIGHT in the tool's or its group's name. Ties keep the index's
      # order.
      def ranked(query, tools)
        wanted = words(query).uniq
        docs = tools.map { |tool| [words("#{tool.group} #{tool.name}"), words(tool.description)] }
        df = Hash.new(0)
        docs.each { |name, text| (name | text).each { |word| df[word] += 1 } }
        count = tools.size.to_f
        scored = tools.each_with_index.filter_map do |tool, i|
          name, text = docs[i]
          score = wanted.sum do |word|
            idf = Math.log(((count - df[word] + 0.5) / (df[word] + 0.5)) + 1)
            if name.include?(word) then NAME_WEIGHT * idf
            elsif text.include?(word) then idf
            else 0
            end
          end
          [tool, score, i] if score.positive?
        end
        scored.sort_by { |_, score, i| [-score, i] }.map(&:first)
      end

      # Lower-case words, split at camelCase too, a plural's s dropped.
      def words(text)
        text.to_s.gsub(/([a-z0-9])([A-Z])/, '\1 \2').downcase.scan(/[a-z0-9]+/).map do |word|
          word.length > 3 && word.end_with?("s") && !word.end_with?("ss") ? word.chomp("s") : word
        end
      end

      # The Tool +name+ names: <group>/<tool>, or an acts_as looked up as
      # it is (never parsed: group names may hold _, and long names are
      # cut). A miss while a group is starting waits for it (its tools may
      # be the one; for a <group>/ name, that group's start only); then a
      # miss is the error text: a failed group's error, else the closest
      # tools.
      # @return [Tool, String]
      def lookup(name, waited: false)
        name = name.strip
        all = groups
        tool = all.lazy.filter_map do |group|
          next unless name.start_with?("#{group.name}/")

          rest = name.delete_prefix("#{group.name}/")
          group.tools.find { |t| t.name == rest }
        end.first
        return tool if tool

        same = all.flat_map(&:tools).select { |t| t.acts_as == name }
        return same.first if same.size == 1
        return "Error: #{name} names #{same.map(&:full_name).join(" and ")}; call one as <group>/<tool>" if same.size > 1

        # A name with a group's <group>/ waits for that group only; any
        # other name (an acts_as) for every one starting.
        named = all.select { |group| name.start_with?("#{group.name}/") }
        starting = (named.empty? ? all : named).select { |group| group.state == :starting }
        unless waited || starting.empty?
          starting.each { |group| source_of(group.name)&.wait(group.name) }
          return lookup(name, waited: true)
        end

        failed = all.find { |group| group.state == :failed && name.start_with?("#{group.name}/") }
        return "Error: MCP server #{failed.name} didn't start: #{failed.error}" if failed

        closest = ranked(name, all.flat_map(&:tools)).take(CLOSEST)
        return "Error: no tool #{name}. Search with #{FIND_NAME}." if closest.empty?

        "Error: no tool #{name}. Closest: #{closest.map(&:full_name).join(", ")}"
      end

      # #lookup's tool, without waiting for a start: nil on a miss.
      def lookup_quietly(name)
        tool = lookup(name, waited: true)
        tool.is_a?(Tool) ? tool : nil
      end

      # The acts_as and label +name+ stands for, from the name alone:
      # <group>/<tool> of a known group (the one that has the tool, else the
      # first whose name it starts with), its source naming the acts_as; a
      # bare name of one of the index's own tools (it acts as itself); or a
      # bare name with a source's prefix as it is (no label). Nil for
      # anything else.
      # @return [Array(String, String), Array(String, nil), nil]
      def claimed(name)
        all = groups
        if (own = all.select { |g| own?(g) }.find { |g| g.tools.any? { |t| t.acts_as == name } })
          return [name, "#{own.name}: #{name}"]
        end

        named = all.select { |group| name.start_with?("#{group.name}/") }
        group = named.find { |g| g.tools.any? { |t| t.name == name.delete_prefix("#{g.name}/") } } || named.first
        if group
          rest = name.delete_prefix("#{group.name}/")
          # A group of the index's own has no source: its tools act as
          # themselves.
          source = source_of(group.name)
          [source ? source.acts_as(group.name, rest) : rest, "#{group.name}: #{rest}"]
        elsif @sources.any? { |source| source.prefix && name.start_with?(source.prefix) }
          [name, nil]
        end
      end

      # The inner arguments as a Hash typed by +tool+'s schema (a JSON text
      # parsed; untyped without a tool), nil when they aren't an object;
      # none is {}.
      def inner_args(args, tool)
        args = {} if args.nil? || (args.is_a?(String) && args.strip.empty?)
        args = Args.coerce({ "args" => args }, { "properties" => { "args" => { "type" => "object" } } })["args"]
        return nil unless args.is_a?(Hash)

        Args.coerce(args, tool&.schema)
      end

      def preview(args)
        line = args.map { |key, value| "#{key}=#{value.is_a?(String) ? value : JSON.generate(value)}" }.join(" ")
        line = line.gsub(/\s+/, " ")
        line.length > PREVIEW_CHARS ? "#{line[0, PREVIEW_CHARS - 1]}…" : line
      end
    end
  end
end
