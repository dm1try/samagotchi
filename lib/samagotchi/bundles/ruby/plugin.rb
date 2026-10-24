# frozen_string_literal: true

# The ruby bundle (docs/plugins.md, The ruby bundle): an `execute` that ran
# RSpec and got no examples at all steers a hint into the running turn, and
# the `ruby_symbol` tool finds a method or class by name (RubySymbol, below).
#
# RSpec prints `0 examples, 0 failures` for a run whose path matched no
# file, whose filter (-e, --tag) matched no example, or whose .rspec
# --pattern hid the specs (a nested project's .rspec overrides one). The
# summary reads green, so the model takes the suite as passing and moves on
# with code no test ever loaded. after_tool_call checks the run: the command
# runs rspec, and every summary line in its output counted 0 examples.
#
# The command: one of its simple commands (split at &&, ||, ;, | and a
# newline, so after a leading `cd x &&` too) starts with `rspec`,
# `bin/rspec` (any path ending in /rspec) or `parallel_rspec`, once leading
# X=… assignments, `bundle exec` and `time` are left out. A program that
# only names rspec (`grep rspec README`, `echo "bundle exec rspec"`) is not
# a run. Only `execute` results count.
#
# The output: every `<N> examples, <M> failures` line (RSpec's summary,
# `0 examples, 0 failures` or `, 3 pending` after it) counts, and the hint
# comes when all of them are 0: parallel_rspec prints one per process, so a
# single process with examples leaves its 0 out of the total. An output with
# no summary line (a spec that fails to load, a missing path, a killed run)
# says what is wrong already: the hint doesn't repeat it.
#
# The hint is a steer: its own user message in the conversation at the
# loop's next boundary, shown as `ruby> nudged: …`, dropped (logged) if the
# model answers first. Nothing is remembered, so the next 0-example run
# hints again: a different command, and it may be the same mistake.

require "open3"
begin
  require "prism"
rescue LoadError
  nil # no ruby_symbol tool (Plugin#register logs it)
end

class Plugin
  HINT = "rspec ran 0 examples: check the path, the filter (-e/--tag) or the .rspec --pattern"
  PROGRAMS = %w[rspec parallel_rspec].freeze
  SUMMARY = /\b(\d+) examples?, (\d+) failures?\b/
  # Where a simple command ends: the next one runs its own program.
  SEGMENTS = /&&|\|\||[;|\n]/
  ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/

  def register(chi)
    chi.on(:after_tool_call) { |event, ctx| after(event, ctx) }
    register_symbol_tool(chi)
  end

  # The ruby_symbol tool, only on Prism 1.0 or newer (Ruby 3.3's default
  # gem is 0.19): below it, one log line per load and no tool.
  def register_symbol_tool(chi)
    unless RubySymbol.available?
      version = defined?(::Prism::VERSION) ? ::Prism::VERSION : "missing"
      chi.ctx.log.warn(:ruby_symbol_unavailable, prism: version, needs: ">= #{RubySymbol::MIN_PRISM}")
      return
    end

    chi.tool "ruby_symbol", RubySymbol::DESCRIPTION,
             params: RubySymbol::PARAMS, label: "looking up",
             preview: ->(args) { [args["name"], args["path"]].compact.join(" in ") },
             targets: ->(args) { { paths: [args["path"] || "."] } } do |args, ctx|
      RubySymbol.new(ctx.cwd).call(args["path"], args["name"])
    end
  end

  def after(event, ctx)
    return unless event[:tool].to_s == "execute"
    return unless self.class.zero_examples?(event[:result])

    call = event[:call]
    return unless call.is_a?(Hash) && self.class.rspec?(call[:content])

    ctx.steer(HINT)
  end

  # Whether one of +command+'s simple commands runs rspec.
  def self.rspec?(command)
    command.to_s.split(SEGMENTS).any? { |segment| PROGRAMS.include?(File.basename(program(segment))) }
  end

  # The program a simple command starts: leading X=… assignments, `bundle
  # exec` and `time` left out ("" for none).
  def self.program(segment)
    words = segment.split(/\s+/).reject(&:empty?)
    words.shift while words.first&.match?(ASSIGNMENT)
    words.shift(2) if words[0] == "bundle" && words[1] == "exec"
    words.shift if words.first == "time"
    words.first.to_s
  end

  # Whether the output has summary lines and every one of them counts 0
  # examples.
  def self.zero_examples?(output)
    counts = output.to_s.scan(SUMMARY).map { |examples, _failures| examples.to_i }
    !counts.empty? && counts.all?(&:zero?)
  end
end

# The ruby_symbol tool: a Ruby file's outline, or a def or class by name with
# its source, from a Prism parse (no index kept: each call parses what it
# needs, chi's own lib/ in ~0.2 s). It stands in for a grep for `def name`
# then a ranged read.
#
# - path a file, no name: the outline, one line per class, module, def (and
#   `X = Data.define`/`Struct.new`/`Class.new`/`Module.new`), nested by
#   indentation, each `start-end  def name(params)`.
# - path a file and a name: each match as a `path:start-end` header then its
#   raw lines, as `read` returns a range (so an `edit` can copy them).
# - path a directory (default the session's cwd) and a name: the same across
#   its .rb files (`git ls-files`, else a glob that skips vendor/,
#   node_modules/, tmp/ and dot folders), up to MAX_SOURCES matches with their
#   source, more as a list of `path:start-end  Namespace#name`.
#
# Names: `bar` (any def bar), `Foo#bar` (an instance method), `Foo.bar` (a
# `def self.bar`, a def in `class << self`, a `def Foo.bar`), `Foo` and
# `Foo::Bar` (a class, module or constant above). The namespace matches as
# a suffix: `Cart#add` finds Shop::Cart#add.
#
# The result is cut at LIMIT characters, at a line boundary, under
# ToolRunner's own cut (whose "read it in parts" doesn't fit here), with a
# note to narrow the name or read the range given.
class RubySymbol
  MIN_PRISM = "1.0"
  LIMIT = 8000
  MAX_SOURCES = 3
  MAX_LIST = 60
  MAX_NEAR = 5
  MAX_FILES = 5000
  MAX_FILE_BYTES = 1_000_000
  SKIP_DIRS = %w[vendor node_modules tmp .git].freeze
  # The calls that make a class or module for the constant they are
  # assigned to (Point = Data.define(:x) do … end).
  MAKERS = { "Class" => %i[new], "Module" => %i[new], "Struct" => %i[new], "Data" => %i[define] }.freeze
  CLASSY = %i[class module const].freeze

  DESCRIPTION = "Find a Ruby method or class by name and get its source, or a file's outline, instead of grep " \
                "for `def name` then read with line numbers. Give a `name` (bar, Foo#bar, Foo.bar, Foo::Bar; " \
                "the namespace may be partial) and a .rb file or a directory as `path`, or a file alone for " \
                "its outline."
  PARAMS = {
    path: { type: "string",
            description: "A .rb file, or a directory to search (default: the working directory)" },
    name: { type: "string",
            description: "bar, Foo#bar (instance method), Foo.bar (class method), Foo or Foo::Bar; " \
                         "leave it out for a file's outline" }
  }.freeze

  # One class, module or def the parse found. +scope+ is its namespace's
  # segments (a class's own name included), +singleton+ whether a def is a
  # class method.
  Entry = Data.define(:kind, :name, :scope, :singleton, :start_line, :end_line, :depth, :label) do
    def qualified
      return scope.join("::") if CLASSY.include?(kind)
      return label if kind == :sclass
      return name if scope.empty?

      "#{scope.join("::")}#{singleton ? "." : "#"}#{name}"
    end

    def range = "#{start_line}-#{end_line}"
  end

  # What a name asks for: a def (+singleton+ true, false or nil for either)
  # or a class-like (+kind+ :class), with the namespace segments it ends in.
  Query = Data.define(:kind, :name, :scope, :singleton) do
    def self.parse(text)
      text = text.strip.delete_prefix("::")
      if text.include?("#")
        scope, name = text.split("#", 2)
        new(kind: :def, name: name, scope: segments(scope), singleton: false)
      elsif (m = text.match(/\A(.+)\.([^.:]+)\z/))
        new(kind: :def, name: m[2], scope: m[1] == "self" ? [] : segments(m[1]), singleton: true)
      else
        parts = segments(text)
        if parts.last.to_s.match?(/\A[A-Z]/)
          new(kind: :class, name: parts.last, scope: parts, singleton: nil)
        else
          new(kind: :def, name: parts.last.to_s, scope: parts[0...-1], singleton: parts.size > 1 || nil)
        end
      end
    end

    def self.segments(text) = text.to_s.split("::").reject(&:empty?)

    def match?(entry)
      if kind == :class
        CLASSY.include?(entry.kind) && entry.scope.last(scope.size) == scope
      else
        entry.kind == :def && entry.name == name && (singleton.nil? || entry.singleton == singleton) &&
          entry.scope.last(scope.size) == scope
      end
    end

    # An entry with the same last segment, any namespace: the near names.
    def near?(entry)
      kind == :class ? CLASSY.include?(entry.kind) && entry.name == name : entry.kind == :def && entry.name == name
    end
  end

  # One parsed file: its source lines and entries, in source order.
  Parsed = Data.define(:path, :lines, :entries)

  def self.available?
    defined?(::Prism::VERSION) && Gem::Version.new(::Prism::VERSION) >= Gem::Version.new(MIN_PRISM)
  rescue ArgumentError
    false
  end

  # The entries of +source+, in source order.
  def self.entries(source)
    [].tap { |out| walk(::Prism.parse(source).value, [], 0, false, out) }
  end

  def self.walk(node, scope, depth, singleton, out)
    case node
    when ::Prism::ClassNode, ::Prism::ModuleNode
      walk_namespace(node, scope, depth, out)
    when ::Prism::SingletonClassNode
      inner = node.expression.is_a?(::Prism::SelfNode) ? scope : scope + constant_segments(node.expression)
      out << entry(node, :sclass, "", inner, false, depth, "class << #{oneline(node.expression.slice)}")
      walk(node.body, inner, depth + 1, true, out) if node.body
    when ::Prism::DefNode
      walk_def(node, scope, depth, singleton, out)
    when ::Prism::ConstantWriteNode, ::Prism::ConstantPathWriteNode
      walk_constant(node, scope, depth, singleton, out)
    else
      node&.compact_child_nodes&.each { |child| walk(child, scope, depth, singleton, out) }
    end
  end

  def self.walk_namespace(node, scope, depth, out)
    path = node.constant_path
    own = constant_segments(path)
    inner = absolute?(path) ? own : scope + own
    kind = node.is_a?(::Prism::ClassNode) ? :class : :module
    label = "#{kind} #{oneline(path.slice)}"
    label += " < #{oneline(node.superclass.slice)}" if kind == :class && node.superclass
    out << entry(node, kind, own.last.to_s, inner, false, depth, label)
    walk(node.body, inner, depth + 1, false, out) if node.body
  end

  def self.walk_def(node, scope, depth, singleton, out)
    receiver = node.receiver
    inner = scope
    inner += constant_segments(receiver) if receiver.is_a?(::Prism::ConstantReadNode) ||
                                            receiver.is_a?(::Prism::ConstantPathNode)
    params = node.parameters ? "(#{oneline(node.parameters.slice)})" : ""
    label = "def #{"#{receiver.slice}." if receiver}#{node.name}#{params}"
    out << entry(node, :def, node.name.to_s, inner, singleton || !receiver.nil?, depth, label)
    walk(node.body, inner, depth + 1, false, out) if node.body
  end

  # X = Data.define(…) do … end (or Struct.new, Class.new, Module.new): a
  # class-like named X, its block's defs inside it. Any other constant
  # write is walked through.
  def self.walk_constant(node, scope, depth, singleton, out)
    call = node.value
    maker = call.is_a?(::Prism::CallNode) && call.receiver.is_a?(::Prism::ConstantReadNode) &&
            MAKERS.fetch(call.receiver.name.to_s, []).include?(call.name)
    return node.compact_child_nodes.each { |child| walk(child, scope, depth, singleton, out) } unless maker

    target = node.is_a?(::Prism::ConstantWriteNode) ? node : node.target
    own = target.is_a?(::Prism::ConstantWriteNode) ? [target.name.to_s] : constant_segments(target)
    inner = scope + own
    head = call.block ? call.slice[0, call.block.location.start_offset - call.location.start_offset] : call.slice
    out << entry(node, :const, own.last.to_s, inner, false, depth, "#{own.join("::")} = #{oneline(head)}")
    walk(call.block, inner, depth + 1, false, out) if call.block
  end

  def self.entry(node, kind, name, scope, singleton, depth, label)
    loc = node.location
    Entry.new(kind: kind, name: name, scope: scope, singleton: singleton, start_line: loc.start_line,
              end_line: loc.end_line, depth: depth, label: label)
  end

  # A constant's segments, its dynamic parts left out
  # (`class Class.new(Foo)::Bar` → ["Bar"]).
  def self.constant_segments(node)
    case node
    when ::Prism::ConstantReadNode then [node.name.to_s]
    when ::Prism::ConstantPathNode then constant_segments(node.parent) + [node.name.to_s]
    else []
    end
  end

  def self.absolute?(node)
    node = node.parent while node.is_a?(::Prism::ConstantPathNode) && node.parent
    node.is_a?(::Prism::ConstantPathNode) && node.parent.nil?
  end

  def self.oneline(text)
    line = text.strip.gsub(/\s*\n\s*/, " ")
    line.length > 100 ? "#{line[0, 99]}…" : line
  end

  def initialize(cwd)
    @cwd = cwd
  end

  def call(path, name)
    path = path.to_s.strip
    name = name.to_s.strip
    full = File.expand_path(path.empty? ? "." : path, @cwd)
    return "Error: no such file or directory: #{path.empty? ? "." : path}" unless File.exist?(full)

    if File.directory?(full)
      return "Error: give a name to search #{display(full)} (or a .rb file as path for its outline)" if name.empty?

      cut(search(files_under(full), Query.parse(name), full, directory: true))
    elsif name.empty?
      cut(outline(parse(full)))
    else
      cut(search([full], Query.parse(name), full, directory: false))
    end
  end

  private

  def parse(file)
    source = File.binread(file).force_encoding(Encoding::UTF_8)
    Parsed.new(path: file, lines: source.lines, entries: self.class.entries(source))
  end

  def outline(parsed)
    entries = parsed.entries
    return "#{display(parsed.path)}: no class, module or def" if entries.empty?

    width = entries.map { |e| e.range.length }.max
    entries.map { |e| "#{e.range.ljust(width)}  #{"  " * e.depth}#{e.label}" }.join("\n")
  end

  def search(files, query, where, directory:)
    parsed = files.filter_map do |file|
      parse(file) if File.file?(file) && File.size(file) <= MAX_FILE_BYTES
    rescue SystemCallError
      nil
    end
    hits = parsed.flat_map { |p| p.entries.select { |e| query.match?(e) }.map { |e| [p, e] } }
    return missing(parsed, query, where) if hits.empty?
    return list(hits) if directory && hits.size > MAX_SOURCES

    hits.map { |p, e| "#{display(p.path)}:#{e.range}\n#{p.lines[(e.start_line - 1)...e.end_line].join}" }.join("\n")
  end

  def list(hits)
    lines = hits.first(MAX_LIST).map { |p, e| "#{display(p.path)}:#{e.range}  #{e.qualified}" }
    more = hits.size > MAX_LIST ? "\n… #{hits.size - MAX_LIST} more" : ""
    "#{hits.size} matches: give a fuller name (Foo#bar, Foo::Bar) or a file as path, " \
      "or read one's path:start-end\n#{lines.join("\n")}#{more}"
  end

  def missing(parsed, query, where)
    near = parsed.flat_map { |p| p.entries.select { |e| query.near?(e) }.map { |e| [p, e] } }.first(MAX_NEAR)
    text = "Error: no def or class named #{query_text(query)} in #{display(where)}"
    return text if near.empty?

    "#{text}. Near names:\n#{near.map { |p, e| "#{display(p.path)}:#{e.range}  #{e.qualified}" }.join("\n")}"
  end

  def query_text(query)
    scope = query.scope.join("::")
    return scope if query.kind == :class

    sep = query.singleton ? "." : "#"
    scope.empty? ? query.name : "#{scope}#{sep}#{query.name}"
  end

  # The .rb files under +dir+: git's (tracked and untracked, ignored left
  # out) when it is a work tree, else a glob skipping SKIP_DIRS.
  def files_under(dir)
    out, status = Open3.capture2("git", "-C", dir, "ls-files", "-z", "--cached", "--others", "--exclude-standard",
                                 "--", "*.rb", err: File::NULL)
    names = status.success? ? out.split("\0").uniq : glob(dir)
    names.first(MAX_FILES).map { |name| File.join(dir, name) }
  rescue SystemCallError
    glob(dir).first(MAX_FILES).map { |name| File.join(dir, name) }
  end

  def glob(dir)
    Dir.glob("**/*.rb", base: dir).reject { |name| name.split("/")[0...-1].any? { |part| SKIP_DIRS.include?(part) } }
  end

  def display(path)
    root = File.join(File.expand_path(@cwd), "")
    return "." if path == File.expand_path(@cwd)

    path.start_with?(root) ? path.delete_prefix(root) : path
  end

  # +text+ cut at LIMIT characters at a line boundary, with a note.
  def cut(text)
    return text if text.length <= LIMIT

    kept = +""
    text.each_line do |line|
      break if kept.length + line.length > LIMIT

      kept << line
    end
    kept = text[0, LIMIT] if kept.empty?
    "#{kept.chomp}\n[ruby_symbol: cut at #{kept.length} of #{text.length} chars: narrow the name, or read a " \
      "path:start-end above]"
  end
end
