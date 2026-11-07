# frozen_string_literal: true

require "json"
require "psych"

module Samagotchi
  # A ```chi-ui fence's YAML, read once on the server (Web::MarkdownRenderer):
  # what the page draws (a picks or a walk) as plain, JSON-ready data, or the
  # one-line reason it stays source. Pure: no web, no Engine.
  #
  # The YAML is read from Psych's node tree, never loaded, so a value stays the
  # text the model wrote (YAML 1.1 would make `- no` false, `1.10` 1.1 and a
  # date a Date), and nothing beyond plain data gets through: an anchor, an
  # alias or a tag is refused. A block that isn't YAML gets one more try after
  # the lenient pass (Lenient), which quotes the free-text values models leave
  # bare. See docs/internals/inline-widgets.md.
  module InlineWidgets
    # error is nil when the block draws; type is set whenever the root names a
    # known one, so a refused block still says what it tried to be.
    Result = Data.define(:type, :data, :lenient, :error) do
      def ok? = error.nil?
      def lenient? = lenient

      # The page's input (data-widget): the data with its type.
      def widget_json = JSON.generate({ "type" => type }.merge(data))
    end

    # The one-line reason a block doesn't draw.
    class Refused < StandardError; end

    # The fence's language. Core draws it, so no bundle can claim it
    # (BlockRenderers::RESERVED).
    LANG = "chi-ui"
    TYPES = %w[picks walk].freeze
    MAX_SOURCE_BYTES = 16 * 1024
    MAX_ROWS = 12
    MAX_STEPS = 30
    ACTORS = (2..5)
    OPTIONS = (2..4)
    MAX_STRING = 300
    # The deepest legal block nests 5 (root, steps, a step, cases, a case);
    # past this it is refused before the stack can overflow.
    MAX_DEPTH = 8
    # How much of a bad type value an error repeats.
    MAX_ECHO = 40

    module_function

    # @return [Result]
    def parse(source)
      source = source.to_s.dup.force_encoding(Encoding::UTF_8)
      lenient = false
      raise Refused, "the block is over #{MAX_SOURCE_BYTES / 1024} KB" if source.bytesize > MAX_SOURCE_BYTES
      raise Refused, "the block is not valid text (UTF-8)" unless source.valid_encoding?

      tree, lenient = load(source)
      raise Refused, "the block isn't a mapping (type: picks or walk first)" unless tree.root.is_a?(Hash)

      type = tree.root["type"]
      raise Refused, "the block needs type: picks or walk" if type.nil?
      raise Refused, "unknown type #{echo(type)} (picks or walk)" unless TYPES.include?(type)

      data = type == "picks" ? Schema.picks(tree.root) : Schema.walk(tree.root)
      Result.new(type: type, data: data, lenient: lenient, error: nil)
    rescue Refused => e
      Result.new(type: TYPES.include?(type) ? type : nil, data: nil, lenient: lenient, error: e.message)
    rescue SystemStackError
      # MAX_DEPTH stops a deep block first; this is the backstop, since a stack
      # overflow is no StandardError and would break every render of the text.
      Result.new(type: nil, data: nil, lenient: lenient, error: "the block nests too deep")
    end

    def echo(type)
      return "(not text)" unless type.is_a?(String)

      type.size > MAX_ECHO ? "#{type[0, MAX_ECHO].inspect}..." : type.inspect
    end

    # [Tree, lenient?]: strict first; only a block that isn't YAML gets the
    # lenient pass. A refused feature (an alias) is final either way.
    def load(source)
      [Tree.new(Psych.parse_stream(source)), false]
    rescue Psych::Exception
      begin
        quoted = Lenient.quote(source)
        [Tree.new(Psych.parse_stream(quoted)), true]
      rescue Psych::SyntaxError => e
        raise Refused, "not YAML: #{e.problem} at line #{e.line}"
      rescue Psych::Exception => e
        raise Refused, "not YAML: #{e.message.lines.first.to_s.strip}"
      end
    end

    # Psych's node tree to Hashes, Arrays and Strings (nil for a plain empty
    # or null value), the scalars' own text, at most MAX_DEPTH deep.
    class Tree
      NULLS = ["", "~", "null", "Null", "NULL"].freeze

      attr_reader :root

      def initialize(stream)
        documents = stream.children
        raise Refused, "the block is empty" if documents.empty?
        raise Refused, "one YAML document only" if documents.size > 1

        @root = node(documents.first.root, 1)
      end

      private

      def node(node, depth)
        raise Refused, "the block nests too deep" if depth > MAX_DEPTH
        raise Refused, "YAML aliases and anchors aren't allowed" if node.is_a?(Psych::Nodes::Alias) || node.anchor
        raise Refused, "YAML tags aren't allowed" if node.tag

        case node
        when Psych::Nodes::Mapping then mapping(node, depth)
        when Psych::Nodes::Sequence then node.children.map { |child| node(child, depth + 1) }
        else scalar(node)
        end
      end

      def mapping(node, depth)
        node.children.each_slice(2).to_h do |key, value|
          key = node(key, depth + 1)
          raise Refused, "a key must be a plain word" unless key.is_a?(String)

          [key, node(value, depth + 1)]
        end
      end

      def scalar(node)
        return nil if node.plain && NULLS.include?(node.value)

        node.value
      end
    end

    # Eval 0013's lenient pass: a free-text value, or a list item that isn't a
    # mapping, goes in quotes unless it is one clean scalar already, so
    # `does: Asked: ...`, `- B: keep 1 h` and `text: "x" is called` all parse.
    # Line by line, so a YAML error's line still points at the source.
    module Lenient
      TEXT_KEYS = %w[title text why does sees behind when recommended].freeze
      ITEM_KEYS = %w[id when goto actor does sees].freeze
      VALUE = /^([ \t]*(?:- )?(?:#{TEXT_KEYS.join("|")}):[ \t]+)(.+?)[ \t]*$/
      ITEM = /^([ \t]*- )(?!(?:#{ITEM_KEYS.join("|")}):)(.+?)[ \t]*$/

      module_function

      def quote(source)
        source.gsub(VALUE) { "#{::Regexp.last_match(1)}#{scalar(::Regexp.last_match(2))}" }
              .gsub(ITEM) { "#{::Regexp.last_match(1)}#{scalar(::Regexp.last_match(2))}" }
      end

      # A value as one double-quoted scalar. Kept as written: one quoted
      # string, or a flow list, mapping or block scalar with no ": " in it.
      def scalar(value)
        return value if value.match?(/\A"[^"]*"\z/) || value.match?(/\A'[^']*'\z/)
        return value if value.match?(/\A[\[{|>]/) && !value.include?(": ")

        wrapped = value.size > 1 && value.start_with?('"') && value.end_with?('"')
        JSON.generate(wrapped ? value[1..-2] : value)
      end
    end

    # The two schemas, as the page reads them: string keys, ids as strings,
    # every other key dropped, and an optional value absent rather than nil.
    module Schema
      module_function

      def picks(tree)
        rows = list(tree["rows"], "rows")
        raise Refused, "picks has #{rows.size} rows (at most #{MAX_ROWS})" if rows.size > MAX_ROWS

        rows = rows.each_with_index.map { |row, index| row(row, index) }
        unique(rows, "row")
        compact("title" => text(tree["title"], "the title"), "rows" => rows)
      end

      def row(row, index)
        where = "row #{index + 1}"
        raise Refused, "#{where} isn't a mapping" unless row.is_a?(Hash)

        id = text(row["id"], "#{where}'s id", required: true)
        where = "row #{id}"
        options = list(row["options"], "#{where}'s options")
        raise Refused, "#{where} has #{options.size} options (#{OPTIONS.min}-#{OPTIONS.max})" unless OPTIONS.cover?(options.size)

        options = options.map { |option| text(option, "#{where}'s option", required: true) }
        recommended = text(row["recommended"], "#{where}'s recommended")
        if recommended && !options.include?(recommended)
          raise Refused, "#{where}: recommended #{recommended.inspect} isn't one of its options"
        end

        compact("id" => id, "text" => text(row["text"], "#{where}'s text", required: true), "options" => options,
                "recommended" => recommended, "why" => text(row["why"], "#{where}'s why"))
      end

      def walk(tree)
        title = text(tree["title"], "the title", required: true)
        actors = list(tree["actors"], "actors").map { |actor| text(actor, "an actor", required: true) }
        raise Refused, "walk has #{actors.size} actors (#{ACTORS.min}-#{ACTORS.max})" unless ACTORS.cover?(actors.size)

        twice = actors.tally.find { |_actor, count| count > 1 }
        raise Refused, "actor #{twice.first.inspect} is listed twice" if twice

        steps = list(tree["steps"], "steps")
        raise Refused, "walk has #{steps.size} steps (at most #{MAX_STEPS})" if steps.size > MAX_STEPS

        steps = steps.each_with_index.map { |step, index| step(step, index, actors) }
        ids = unique(steps, "step")
        steps.each { |step| targets(step, ids) }
        { "title" => title, "actors" => actors, "steps" => steps }
      end

      def step(step, index, actors)
        where = "step #{index + 1}"
        raise Refused, "#{where} isn't a mapping" unless step.is_a?(Hash)

        id = text(step["id"], "#{where}'s id", required: true)
        where = "step #{id}"
        actor = text(step["actor"], "#{where}'s actor", required: true)
        raise Refused, "#{where}: actor #{actor.inspect} isn't one of the actors" unless actors.include?(actor)

        does = text(step["does"], "#{where}'s does")
        sees = text(step["sees"], "#{where}'s sees")
        raise Refused, "#{where} needs does or sees" unless does || sees

        compact("id" => id, "actor" => actor, "does" => does, "sees" => sees,
                "behind" => text(step["behind"], "#{where}'s behind"), "next" => text(step["next"], "#{where}'s next"),
                "cases" => cases(step, where))
      end

      # cases, and eval round 1's name for them (branches), as one list.
      def cases(step, where)
        given = %w[cases branches].filter_map { |key| list(step[key], "#{where}'s #{key}") unless step[key].nil? }
        return nil if given.empty?

        given.flatten(1).map do |item|
          raise Refused, "#{where}: each case needs when and goto" unless item.is_a?(Hash)

          { "when" => text(item["when"], "#{where}'s when", required: true),
            "goto" => text(item["goto"], "#{where}'s goto", required: true) }
        end
      end

      def targets(step, ids)
        names = [step["next"], *Array(step["cases"]).map { |item| item["goto"] }].compact
        missing = names.find { |name| !ids.include?(name) }
        raise Refused, "step #{step["id"]}: #{missing.inspect} isn't a step" if missing
      end

      def unique(items, noun)
        ids = items.map { |item| item["id"] }
        twice = ids.tally.find { |_id, count| count > 1 }
        raise Refused, "#{noun} id #{twice.first.inspect} is used twice" if twice

        ids
      end

      def list(value, where)
        raise Refused, "#{where} must be a non-empty list" unless value.is_a?(Array) && !value.empty?

        value
      end

      def text(value, where, required: false)
        raise Refused, "#{where} must be text, not a #{value.is_a?(Hash) ? "mapping" : "list"}" if value.is_a?(Hash) || value.is_a?(Array)

        value = value&.strip
        value = nil if value && value.empty?
        raise Refused, "#{where} is missing" if required && value.nil?
        raise Refused, "#{where} is over #{MAX_STRING} characters" if value && value.size > MAX_STRING

        value
      end

      def compact(hash) = hash.compact
    end
  end
end
