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
  # A method called in the file: its name and, when the receiver is a constant,
  # that constant's parts (nil for a call on an object or a bare call). scope is
  # the namespaces around the call, so a receiver can be resolved like a ref.
  Call = Data.define(:receiver, :name, :line, :scope)
  # A method the file defines in a namespace. visibility: :public unless a
  # `private`, `protected` or `module_function` line in that body said otherwise.
  Method = Data.define(:name, :scope, :line, :visibility)

  # One file, parsed but never executed.
  class Scan
    MIXINS = %i[include extend prepend].freeze
    # Blocks whose body runs at call time, not when the file loads.
    LAZY = %i[define_method].freeze
    # The visibility lines of a class or module body.
    VISIBILITY = %i[private protected module_function].freeze

    attr_reader :path, :defs, :refs, :requires, :autoloads, :calls, :methods

    def initialize(path, root = nil)
      @abs = File.expand_path(path)
      # Repo-relative for the report; the require targets need the real path.
      @path = root ? @abs.sub(%r{\A#{Regexp.escape(File.expand_path(root))}/}, "") : path
      @defs = []
      @refs = []
      @requires = []
      @autoloads = []
      @calls = []
      @methods = []
      # Visibility of the namespace a body is in, and of single methods named
      # by `private :foo` or `private def foo`.
      @visibility = {}
      @named_visibility = Hash.new { |hash, key| hash[key] = {} }
      @local_paths = {}
      @loop_autoload_names = {}
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
        note_method(node, scope)
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
        add_autoload(node, scope)
        return
      end
      register_loop_autoload(node) if name == :each
      if node.receiver.nil? && MIXINS.include?(name) && !call
        arguments.each { |arg| note(parts(arg), scope, node.location.start_line, false, name.to_s) }
        return
      end
      if node.receiver.nil? && VISIBILITY.include?(name)
        note_visibility(name, arguments, scope)
      end
      if name == :const_set
        const = literal(arguments.first)
        define([const], scope, node.location.start_line) if const
      end
      @calls << Call.new(parts(node.receiver), name.to_s, node.location.start_line, scope.dup)
      node.compact_child_nodes.each { |child| walk(child, scope, LAZY.include?(name) || call) }
    end

    # A bare `private` sets the visibility of the defs that follow it in this
    # body; `private def foo` and `private :foo` name one method.
    def note_visibility(name, arguments, scope)
      key = scope.join("::")
      if arguments.empty?
        @visibility[key] = name == :module_function ? :public : name
      else
        arguments.each do |arg|
          method = if arg.class.name.end_with?("SymbolNode")
                     arg.value
                   else
                     (arg.respond_to?(:name) ? arg.name : nil)
                   end
          @named_visibility[key][method] = name == :module_function ? :public : name if method
        end
      end
    end

    def note_method(node, scope)
      key = scope.join("::")
      visibility = @named_visibility[key][node.name] || @visibility[key] || :public
      @methods << Method.new(node.name.to_s, scope, node.location.start_line, visibility)
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

    def add_autoload(node, scope)
      arguments = node.arguments&.arguments || []
      name, target = arguments
      target_path = autoload_target_path(target)
      names = @loop_autoload_names[node.location.start_offset]
      if names
        @autoloads.concat(names.map { |part| Autoload.new((scope + [part]).join("::"), target_path, node.location.start_line) })
      else
        parts = name.class.name.end_with?("SymbolNode") ? [name.value] : nil
        @autoloads << Autoload.new(parts && (scope + parts).join("::"), target_path, node.location.start_line)
      end
    end

    def autoload_target_path(target)
      case target
      when nil then nil
      when Prism::StringNode then target.unescaped
      when Prism::CallNode then expand_path(target)
      else @local_paths[target.respond_to?(:name) ? target.name.to_s : ""]
      end
    end

    def register_loop_autoload(node)
      return unless node.receiver&.class&.name == "Prism::ArrayNode" && node.block

      names = node.receiver.elements
      return unless names.any? && names.all? { _1.class.name.end_with?("SymbolNode") }

      parameters = node.block.parameters&.parameters&.requireds
      return unless parameters&.size == 1

      parameter = parameters.first.name
      calls = node.block.body&.compact_child_nodes&.select do |child|
        child.instance_of?(Prism::CallNode) && child.receiver.nil? && child.name == :autoload
      end
      return unless calls&.size == 1

      autoload = calls.first
      arguments = autoload.arguments&.arguments || []
      return unless arguments.first&.class&.name == "Prism::LocalVariableReadNode"
      return unless arguments.first.name == parameter

      @loop_autoload_names[autoload.location.start_offset] = names.map(&:value)
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
