# frozen_string_literal: true

require "prism"

# script/load-check: what one file says, read with Prism and never loaded.
# See script/load-check and docs/testing.md.
module LoadCheck
  # A require line: target as written ("samagotchi/engine") or, for
  # require_relative and the File.expand_path form, the absolute path.
  # load_time: false when the line sits inside a method body.
  Require = Data.define(:target, :line, :load_time)
  # autoload NAME, <path>; name is nil when it is not a literal (a loop),
  # which means "whatever this file defines is reachable".
  Autoload = Data.define(:name, :target, :line)
  # A constant the file defines, in the lexical scope it sits in.
  Def = Data.define(:parts, :scope, :line)
  # A constant the file names. stage: :load (evaluated when the file loads) or
  # :call (inside a method body).
  Ref = Data.define(:parts, :scope, :line, :stage, :context)

  # One file, parsed but never executed.
  class Scan
    MIXINS = %i[include extend prepend].freeze
    # Blocks whose body runs at call time, not when the file loads.
    LAZY = %i[define_method].freeze

    attr_reader :path, :defs, :refs, :requires, :autoloads

    def initialize(path, root = nil)
      @abs = File.expand_path(path)
      # Repo-relative for the report; the require targets need the real path.
      @path = root ? @abs.sub(%r{\A#{Regexp.escape(File.expand_path(root))}/}, "") : path
      @defs = []
      @refs = []
      @requires = []
      @autoloads = []
      @local_paths = {}
      parse
    end

    private

    def parse
      walk(Prism.parse(File.read(@abs)).value, [], false)
    end

    # scope: the namespaces lexically around the node; call: are we inside a
    # method body, where a constant is only needed when the method runs.
    def walk(node, scope, call)
      return if node.nil?

      case node.class.name
      when "Prism::ModuleNode", "Prism::ClassNode"
        open_namespace(node, scope, call)
      when "Prism::SingletonClassNode"
        walk(node.body, scope, call) if node.respond_to?(:body)
      when "Prism::ConstantWriteNode"
        parts = name_parts(node)
        define(parts, scope, node.location.start_line) if parts
        walk(node.value, scope, call)
      when "Prism::ConstantPathWriteNode"
        parts = parts(node.target)
        define(parts, scope, node.location.start_line) if parts
        note_parents(parts, scope, node.location.start_line, call)
        walk(node.value, scope, call)
      when "Prism::ConstantOrWriteNode", "Prism::ConstantAndWriteNode", "Prism::ConstantOperatorWriteNode"
        parts = name_parts(node)
        note(parts, scope, node.location.start_line, call, "read of a constant")
        walk(node.value, scope, call)
      when "Prism::MultiWriteNode"
        targets = node.respond_to?(:lefts) ? node.lefts : node.lhs
        targets.each { |target| parts = parts(target); define(parts, scope, node.location.start_line) if parts }
        walk(node.value, scope, call)
      when "Prism::DefNode"
        # A default argument is evaluated when the method is called, so it is a
        # call-time reference (Rule 1), not a load-time one.
        walk(node.parameters, scope, true) if node.parameters
        walk(node.body, scope, true)
      when "Prism::DefinedNode"
        # defined?(X) is a guard: a missing X is what the code expects.
      when "Prism::LocalVariableWriteNode"
        # `delivery = File.expand_path("session_inbox_delivery", __dir__)` then
        # `autoload name, delivery`: keep the path the local holds.
        value = node.value
        path = string_value(value) || expand_path(value)
        @local_paths[node.name.to_s] = path if path
        walk(value, scope, call)
      when "Prism::ConstantReadNode", "Prism::ConstantNode", "Prism::ConstantPathNode"
        parts = parts(node)
        context = node.class.name.end_with?("ConstantPathNode") ? "qualified reference" : "reference"
        note(parts, scope, node.location.start_line, call, context)
      when "Prism::CallNode"
        call_node(node, scope, call)
      else
        node.compact_child_nodes.each { |child| walk(child, scope, call) }
      end
    end

    def open_namespace(node, scope, call)
      parts = name_parts(node)
      unless parts
        # class self, class obj: no constant defined here.
        walk(node.body, scope, call) if node.respond_to?(:body)
        return
      end
      define(parts, scope, node.location.start_line)
      # `class Engine::Parts` needs Engine to exist at that moment.
      note_parents(parts, scope, node.location.start_line, call)
      superclass = node.respond_to?(:superclass) ? node.superclass : nil
      note(parts(superclass), scope, node.location.start_line, false, "superclass") if superclass
      walk(node.body, scope + parts, call)
    end

    def note_parents(parts, scope, line, call)
      return if parts.nil? || parts.size < 2

      (1...parts.size).each { |i| note(parts[0...i], scope, line, call, "namespace the path opens") }
    end

    def call_node(node, scope, call)
      name = node.name
      arguments = node.arguments&.arguments || []
      if node.receiver.nil? && %i[require require_relative].include?(name)
        arguments.each { |arg| add_require(name, arg, node.location.start_line, !call) }
        return
      end
      if node.receiver.nil? && name == :autoload
        add_autoload(arguments, scope, node.location.start_line)
        return
      end
      if node.receiver.nil? && MIXINS.include?(name) && !call
        arguments.each { |arg| note(parts(arg), scope, node.location.start_line, false, name.to_s) }
        return
      end
      if name == :const_set
        const = literal(arguments.first)
        define([const], scope, node.location.start_line) if const
      end
      node.compact_child_nodes.each { |child| walk(child, scope, LAZY.include?(name) || call) }
    end

    def add_require(kind, arg, line, load_time)
      target = case arg.class.name
               when "Prism::StringNode"
                 kind == :require_relative ? File.expand_path(string_value(arg), File.dirname(@abs)) : string_value(arg)
               when "Prism::CallNode" then expand_path(arg)
               else @local_paths[arg.respond_to?(:name) ? arg.name.to_s : ""]
               end
      @requires << Require.new(target, line, load_time) if target
    end

    def add_autoload(arguments, scope, line)
      name, target = arguments
      parts = name.class.name.end_with?("SymbolNode") ? [name.value] : nil
      target_path = case target
                    when nil then nil
                    when Prism::StringNode then target.unescaped
                    when Prism::CallNode then expand_path(target)
                    else @local_paths[target.respond_to?(:name) ? target.name.to_s : ""]
                    end
      @autoloads << Autoload.new(parts && (scope + parts).join("::"), target_path, line)
    end

    # require File.expand_path("engine/log", __dir__) and the autoload form.
    def expand_path(node, _line = nil)
      return nil unless node.respond_to?(:name) && node.name == :expand_path

      first = node.arguments&.arguments&.first
      return nil unless first.class.name.end_with?("StringNode")

      File.expand_path(first.unescaped, File.dirname(@abs))
    end

    def string_value(node)
      node.respond_to?(:unescaped) ? node.unescaped : nil
    end

    def literal(node)
      node.respond_to?(:value) ? node.value : nil
    end

    def const?(name)
      name.to_s.match?(/\A[A-Z]/)
    end

    # A constant name as written: ["Engine"] or ["Samagotchi", "Engine"].
    def parts(node)
      return nil if node.nil?

      if node.class.name.end_with?("ConstantPathNode")
        head = parts(node.compact_child_nodes.first)
        name = node.name.to_s
        head && const?(name) ? head + [name] : nil # a dynamic part (obj::Foo) is not a constant name
      elsif node.respond_to?(:name) && const?(node.name)
        [node.name.to_s]
      end
    end

    # Prism names a namespace's name two ways: a Symbol plus a constant_path,
    # or the path node itself.
    def name_parts(node)
      path = node.respond_to?(:constant_path) ? node.constant_path : nil
      parts(path || (node.respond_to?(:name) && node.name.is_a?(Prism::Node)) ? node.name : node)
    end

    def define(parts, scope, line)
      @defs << Def.new(parts, scope, line)
    end

    def note(parts, scope, line, call, context)
      return if parts.nil? || parts.empty?

      @refs << Ref.new(parts, scope, line, call ? :call : :load, context)
    end
  end
end
