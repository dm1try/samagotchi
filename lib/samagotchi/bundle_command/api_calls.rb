# frozen_string_literal: true

require "prism"
require_relative "../config"
require_relative "../version"
require_relative "../plugin/api"
require_relative "../plugin/context"

module Samagotchi
  class BundleCommand
    # What a plugin's source calls of the plugin API, read with Prism
    # (`chi bundle check`'s `api` and `requires-chi-floor`). The classes are
    # the source of truth: a name is checked against their public methods
    # and a keyword against the method's parameters, so nothing here lists
    # the API. It sees only calls written on a local `ctx` or `chi` itself
    # (ctx.sessions.nope; not `s = ctx.sessions; s.nope`): a miss, never a
    # false alarm, is what a variable costs.
    class ApiCalls
      # A call that isn't there, or a keyword its method doesn't take.
      Finding = Data.define(:line, :message, :fix)

      # What each API object's member gives: the only list here, of the
      # objects behind a call (their names and keywords are their classes').
      # Resolved on use: Sessions alone loads ~150 files.
      MEMBERS = {
        "Plugin::Api" => { ctx: "Plugin::Context" },
        "Plugin::Context" => { sessions: "Plugin::Sessions", context: "Plugin::AttachedContext", http: "Plugin::Http",
                               judgments: "Plugin::Judgments", cost: "SessionMetrics::Cost", usage: "SessionMetrics::Usage",
                               log: "Plugin::Context::Logger" }
      }.freeze
      ROOTS = { ctx: "Plugin::Context", chi: "Plugin::Api" }.freeze

      def initialize(source)
        @result = Prism.parse(source)
        @nodes = []
        return unless @result.success?

        queue = [@result.value]
        while (node = queue.pop)
          @nodes << node
          queue.concat(node.compact_child_nodes)
        end
        @nodes.sort_by! { |node| node.location.start_offset }
      end

      # Each call's keywords, as "chi.toolkit(groups:)": the call's receiver
      # as written, its name and the keyword (with or without parens, over
      # lines). Nothing when the source doesn't parse.
      # @return [Array<String>]
      def keywords
        calls.flat_map do |node|
          next [] unless node.receiver && node.arguments

          keyword_names(node).map { |keyword| "#{node.receiver.slice}.#{node.name}(#{keyword}:)" }
        end
      end

      # What the source calls that this chi's API lacks, in source order.
      # Nothing when it doesn't parse (the install's error says so). A name
      # the source guards with respond_to? is a newer chi's, on purpose.
      # @return [Array<Finding>]
      def findings
        calls.filter_map do |node|
          owner = owner_of(node.receiver) or next
          klass = class_named(owner)
          if klass.public_method_defined?(node.name)
            keyword_finding(node, klass)
          elsif !guarded?(node.name)
            missing_call(node, klass)
          end
        end
      end

      private

      def calls = @nodes.grep(Prism::CallNode)

      # The API class +receiver+ is an instance of, by how it is written, or nil.
      def owner_of(receiver)
        case receiver
        when Prism::LocalVariableReadNode then ROOTS[receiver.name] unless shadowed?(receiver.name)
        when Prism::CallNode then MEMBERS.dig(owner_of(receiver.receiver), receiver.name)
        end
      end

      # A local ctx or chi the plugin set to anything but chi.ctx isn't the API.
      def shadowed?(name)
        @nodes.grep(Prism::LocalVariableWriteNode).any? { |write| write.name == name && write.value.slice != "chi.ctx" }
      end

      def guarded?(name)
        calls.any? do |node|
          next false unless node.name == :respond_to? && owner_of(node.receiver)

          first = node.arguments&.arguments&.first
          first.respond_to?(:unescaped) && first.unescaped == name.to_s
        end
      end

      def class_named(name) = Samagotchi.const_get(name)

      def missing_call(node, klass)
        near = Config.near_names(node.name.to_s, klass.public_instance_methods(false).map(&:to_s)).first
        call = "#{node.receiver.slice}.#{node.name}"
        fix = near ? "did you mean #{node.receiver.slice}.#{near}? docs/plugins.md has the API" : "docs/plugins.md has the API"
        Finding.new(line: node.location.start_line, message: "#{call} isn't in chi #{VERSION}'s plugin API", fix: fix)
      end

      # One Finding, the first keyword the method doesn't take. A method with
      # no keywords takes a hash as an argument; one with ** takes any.
      def keyword_finding(node, klass)
        parameters = klass.instance_method(node.name).parameters
        return nil if parameters.any? { |kind, _| kind == :keyrest }

        taken = parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }.map(&:to_s)
        return nil if taken.empty?

        unknown = keyword_names(node).find { |keyword| !taken.include?(keyword) } or return nil
        near = Config.near_names(unknown, taken).first
        takes = "it takes #{taken.map { |name| "#{name}:" }.join(", ")}"
        Finding.new(line: node.location.start_line, message: "#{node.receiver.slice}.#{node.name} takes no #{unknown}: in chi #{VERSION}",
                    fix: near ? "did you mean #{near}:? #{takes}" : takes)
      end

      def keyword_names(node)
        Array(node.arguments&.arguments).grep(Prism::KeywordHashNode).flat_map do |hash|
          hash.elements.filter_map { |pair| pair.key.unescaped if pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode) }
        end
      end
    end
  end
end
