# frozen_string_literal: true

module DeadCode
  # The methods defined under lib/ that nothing names: a name counts as used
  # when it appears in lib, spec, bin, script, the erb templates, the Rakefile,
  # Gemfile, gemspec or the custom cops as an identifier, constant, method
  # name, label or a word inside a string. Its definitions take one use each
  # off, so a name used only where it is defined ends at 0 or below.
  # A heuristic: `send(:foo)` counts (the symbol is a use), but a name built at
  # run time ("on_#{event}") doesn't, so each row carries what may explain it.
  class Scan
    # Hooks, protocol and operator methods Ruby or a library calls by itself.
    SKIP = %w[
      initialize to_s inspect call respond_to_missing? method_missing == <=> === each to_h to_a to_str to_ary
      to_proc to_json hash eql? [] []= << >> + - * / % ! =~ coerce inherited included extended prepended
      method_added each_pair to_i to_f to_sym succ size length empty? close dup clone initialize_copy
      marshal_dump marshal_load deconstruct deconstruct_keys freeze call! run start stop
    ].to_set.freeze

    FRAMEWORK = {
      "pretty_print" => "framework: pp",
      "before_setup" => "framework: Minitest hook",
      "after_teardown" => "framework: Minitest hook",
      "fileno" => "duck-typed IO (likely)"
    }.freeze

    # The words of a dispatch by name: "on_#{event}" calls on_<event>.
    DISPATCH = { "on_" => "dispatched by name (on_<event>)", "run_" => "dispatched by name (run_<sub>)" }.freeze

    LIST_TOKENS = %i[IDENTIFIER CONSTANT METHOD_NAME FLOAT].freeze

    # One unreferenced definition. notes: "docs" (a doc names it),
    # "dyn-prefix" (an interpolated string starts like it), "bundle-spec",
    # or a FRAMEWORK/DISPATCH explanation.
    Row = Data.define(:name, :path, :line, :singleton, :notes) do
      def explained? = notes.any? { |note| note.start_with?("framework", "duck-typed", "dispatched") }
    end

    Result = Data.define(:rows, :defs, :names) do
      def review_worthy = rows.reject(&:explained?)
    end

    def initialize(root:)
      @root = root
      @counts = Hash.new(0)
      @defs = Hash.new { |hash, name| hash[name] = [] }
      @prefixes = Set.new
    end

    # @return [Result]
    def run
      Dir.chdir(@root) { corpus.each { |path| read(path) } }
      Result.new(rows: rows.sort_by { [_1.path, _1.line] }, defs: @defs.values.sum(&:size), names: @defs.size)
    end

    private

    def corpus
      files = Dir["lib/**/*.rb"] + Dir["spec/**/*.rb"] + Dir["bin/*"] + Dir["script/*"] + Dir["script/**/*.rb"] +
              Dir["lib/**/*.erb"] + %w[Rakefile Gemfile samagotchi.gemspec] + Dir["rubocop/**/*.rb"]
      # The scan's own words (SKIP, FRAMEWORK) would count as uses.
      files.uniq.reject { _1.start_with?("script/dead_code/") || _1 == "script/dead-code" }.select { File.file?(_1) }
    end

    def read(path)
      src = File.read(path)
      collect_defs(Prism.parse(src).value, path)
      Prism.lex(src).value.each { |token, _| count(token) }
    end

    def collect_defs(root, path)
      lib = path.start_with?("lib/") && path.end_with?(".rb")
      stack = [root]
      until stack.empty?
        node = stack.pop
        define(node, path) if lib && node.is_a?(Prism::DefNode)
        prefix(node) if node.is_a?(Prism::InterpolatedStringNode) || node.is_a?(Prism::InterpolatedSymbolNode)
        stack.concat(node.compact_child_nodes)
      end
    end

    def define(node, path)
      name = node.name.to_s.chomp("=")
      @defs[name] << [path, node.location.start_line, node.receiver ? "self." : ""]
      @counts[name] -= 1
    end

    def prefix(node)
      first = node.parts.first
      @prefixes << first.unescaped if first.respond_to?(:unescaped) && !first.unescaped.empty?
    end

    def count(token)
      value = token.value
      case token.type
      when *LIST_TOKENS
        @counts[value.chomp("=")] += 1
        # RSpec predicate matchers: be_foo calls foo?, have_foo calls has_foo?.
        @counts["#{Regexp.last_match(1)}?"] += 1 if value =~ /\Abe_(\w+)\z/
        @counts["has_#{Regexp.last_match(1)}?"] += 1 if value =~ /\Ahave_(\w+)\z/
      when :LABEL then @counts[value.chomp(":")] += 1
      when :STRING_CONTENT then value.scan(/[A-Za-z_]\w*[?!]?/) { @counts[_1] += 1 }
      end
    end

    def rows
      docs = Dir.chdir(@root) { (Dir["docs/**/*.md"] + Dir["AGENTS.md"]).map { File.read(_1) }.join("\n") }
      @defs.flat_map do |name, sites|
        next [] if SKIP.include?(name) || name.match?(/\A\W+\z/) || @counts[name].positive?

        dynamic = @prefixes.any? { |prefix| prefix.size >= 3 && name.start_with?(prefix) }
        sites.map { |path, line, singleton| Row.new(name, path, line, singleton, notes(name, path, docs, dynamic)) }
      end
    end

    def notes(name, path, docs, dynamic)
      notes = []
      notes << "docs" if docs.include?(name)
      notes << "dyn-prefix" if dynamic
      explanation = FRAMEWORK[name]
      explanation ||= DISPATCH.find { |prefix, _| name.start_with?(prefix) }&.last if dynamic
      explanation ||= "bundle-spec" if path.include?("/spec/")
      notes << explanation if explanation
      notes
    end
  end
end
