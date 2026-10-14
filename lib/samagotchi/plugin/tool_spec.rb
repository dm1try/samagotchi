# frozen_string_literal: true

require "json"
require_relative "../tools/args"

module Samagotchi
  module Plugin
    # A checked tool declaration: what Api#tool, ToolSet#tool and
    # ToolSpec.build make, and what Tools::Registry#register gets
    # (#entry_fields). +schema+ is what reaches the prompt ({name:,
    # description:, parameters:}); the block, preview:, targets: and refs:
    # never do.
    class ToolSpec < Data.define(:name, :schema, :label, :preview, :targets, :refs, :block)
      TOOL_NAME = /\A[a-z][a-z0-9_]{0,47}\z/
      PARAM_NAME = /\A[a-z_][a-z0-9_]*\z/i

      # A checked tool declaration from #tool's arguments (Api#tool and
      # ToolSet#tool pass theirs on, so a new keyword is added here).
      # @return [ToolSpec]
      def self.build(name, description, params: {}, schema: nil, label: nil, preview: nil, targets: nil, refs: nil,
                     &block)
        raise ArgumentError, "tool #{name.inspect} needs a block" unless block

        name = name.to_s
        raise ArgumentError, "tool name #{name.inspect} must be a-z, 0-9 and _ (at most 48)" unless name.match?(TOOL_NAME)
        raise ArgumentError, "tool #{name}: preview must respond to #call" if preview && !preview.respond_to?(:call)
        raise ArgumentError, "tool #{name}: targets must respond to #call" if targets && !targets.respond_to?(:call)
        raise ArgumentError, "tool #{name}: refs must respond to #call" if refs && !refs.respond_to?(:call)

        parameters = schema ? schema_parameters(name, schema) : params_schema(name, params)
        new(name: name, schema: { name: name, description: description.to_s, parameters: parameters },
            label: label&.to_s, preview: preview, targets: targets, refs: refs, block: block)
      end

      # Make +bundle+'s tools in +registry+ the +specs+: its tools not in
      # them go; a new one, or one whose schema or label changed, is
      # registered (a changed one again, in its place: Tools::Registry
      # orders bundle tools by bundle and name); an unchanged one is kept
      # as it is, but for its block, preview:, targets: and refs:, swapped
      # in place: none of them reaches the prompt, so not a change (that
      # would build the prompts again). A name
      # another source has is left out. Called on the turn thread
      # (Engine#apply_staged_tools!).
      # @return [Hash] {changed: Boolean, skipped: [String] (why)}
      def self.apply(registry, bundle, specs, context)
        wanted = specs.to_h { |spec| [spec.name, spec] }
        changed = false
        registry.by_source(bundle).each do |entry|
          if (spec = wanted[entry.name]) && spec.schema == entry.schema && spec.label == entry.label
            spec.entry_fields(context).slice(:handler, :preview, :targets, :refs).each { |key, value| entry[key] = value }
            next
          end

          registry.unregister(entry.name)
          changed = true
        end
        skipped = []
        specs.each do |spec|
          if (taken = registry[spec.name])
            skipped << "tool #{spec.name} is already registered (#{taken.source})" unless taken.source == bundle
            next
          end

          registry.register(spec.name, source: bundle, **spec.entry_fields(context))
          changed = true
        end
        { changed: changed, skipped: skipped }
      end

      # A tool's result as the model reads it: a String (a ToolResult too,
      # with its images) as it is, a Hash or Array as JSON (its #to_s is
      # Hash#inspect, which changes with the Ruby version), else #to_s.
      def self.result_text(result)
        case result
        when String then result
        when Hash, Array then JSON.generate(result)
        else result.to_s
        end
      rescue JSON::GeneratorError
        result.to_s
      end

      # A tool call's arguments as a plugin sees them: the parsers' args:
      # (a call built without one, in a spec say: the call without its
      # name), string keys, typed by +parameters+, frozen.
      def self.args_of(call, parameters = nil)
        given = call[:args].is_a?(Hash) ? call[:args] : call.reject { |key, _| %i[name args].include?(key) }
        Tools::Args.coerce(given, parameters).freeze
      end

      # A JSON Schema with symbol keys (property names included), as
      # ToolDeclarations::TOOL_SCHEMAS has them.
      def self.symbolize(value)
        case value
        when Hash then value.to_h { |key, item| [key.to_sym, symbolize(item)] }
        when Array then value.map { |item| symbolize(item) }
        else value
        end
      end

      # The parameters object from params: (name => property spec).
      def self.params_schema(name, params)
        raise ArgumentError, "tool #{name}: params must be a Hash" unless params.is_a?(Hash)

        required = []
        properties = params.each_with_object({}) do |(param, spec), acc|
          param = param.to_s
          raise ArgumentError, "tool #{name}: parameter name #{param.inspect} is not a plain word" unless param.match?(PARAM_NAME)
          raise ArgumentError, "tool #{name}: parameter #{param} must be a Hash {type:, description:}" unless spec.is_a?(Hash)

          spec = symbolize(spec)
          required << param if spec.delete(:required) == true
          acc[param.to_sym] = { type: (spec.delete(:type) || "string").to_s, description: spec.delete(:description).to_s }.merge(spec)
        end
        { type: "object", properties: properties, required: required }
      end
      private_class_method :params_schema

      # The parameters object from schema: (a JSON Schema object).
      def self.schema_parameters(name, schema)
        raise ArgumentError, "tool #{name}: schema must be a Hash" unless schema.is_a?(Hash)

        schema = symbolize(schema)
        raise ArgumentError, "tool #{name}: schema must be {type: \"object\", properties: {…}}" unless schema.fetch(:type, "object").to_s == "object"

        properties = schema[:properties] || {}
        raise ArgumentError, "tool #{name}: schema properties must be a Hash" unless properties.is_a?(Hash)

        { type: "object", properties: properties, required: Array(schema[:required]).map(&:to_s) }
          .merge(schema.except(:type, :properties, :required))
      end
      private_class_method :schema_parameters

      # A field by name, as a Hash reads (spec[:schema]; nil for a name it
      # hasn't): bundles read the spec Api.tool_spec gives that way.
      def [](key) = (public_send(key) if members.include?(key))

      # Registry#register's keywords for it: its block wrapped as a handler
      # (typed args, the Context), preview, targets, refs.
      def entry_fields(context)
        block = self.block
        parameters = schema[:parameters]
        preview = per_call(self.preview, parameters)
        {
          schema: schema, label: label,
          handler: lambda { |call, _kctx|
            result = block.call(ToolSpec.args_of(call, parameters), context)
            ToolSpec.result_text(result)
          },
          preview: preview && ->(call) { preview.call(call)&.to_s },
          targets: per_call(targets, parameters),
          refs: per_call(refs, parameters)
        }
      end

      private

      # A plugin's args → value lambda (+fn+) as call → value: it gets the
      # call's typed args (ToolSpec.args_of), as the tool's block does. nil
      # without one.
      def per_call(fn, parameters)
        fn && ->(call) { fn.call(ToolSpec.args_of(call, parameters)) }
      end
    end
  end
end
