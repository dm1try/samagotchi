# frozen_string_literal: true

require_relative "../cancellation_controller"
require_relative "../cache_confirm"
require_relative "../plugin/context"
require_relative "../session_metrics/cost"
require_relative "../session_metrics/usage"
require_relative "recorder"

module Samagotchi
  module Testing
    # The Engine side of a bundle's Context, recorded: a real Plugin::Host
    # with every member set, its values read from the Recorder at each call
    # and its actions landing in it.
    module Host
      # What CacheConfirm.ask reads of an Engine, from the Recorder's
      # history: and context_tokens:.
      CacheEngine = Struct.new(:history, :tokens) do
        def history? = history ? true : false
        def cache_restart_tokens = tokens
        def cache_restart_anthropic? = false
      end

      module_function

      # @param recorder [Recorder]
      # @param toolkits [#call] → the toolkit names ctx.use_toolkit accepts
      # @param tool_names [#call] → the declared tools when none is set
      # @return [Plugin::Host]
      def build(recorder, toolkits: -> { [] }, tool_names: -> { [] })
        # ctx.http's default cancel: a cancelled controller while the test
        # says the turn is (cancelled: true), none otherwise.
        stopped = CancellationController.new.tap { |controller| controller.cancel!(:test) }
        Plugin::Host.new(
          session_id: -> { recorder[:session_id] },
          cwd: -> { recorder[:cwd] },
          messages: -> { recorder[:messages] },
          messages_partial: -> { recorder[:messages_partial] },
          notify: ->(text, level, label, fallback_for: nil) { recorder.notify(text, level, label, fallback_for) },
          ask_user: ->(question) { recorder.ask_user(question) },
          cancelled: -> { recorder[:cancelled] },
          card: ->(**card) { recorder.card(**card) },
          ask_model: lambda { |request, timeout:, max_tokens:, cancel_controller:, model: nil, source: nil|
            recorder.ask_model(request, timeout: timeout, max_tokens: max_tokens, cancel_controller: cancel_controller,
                                        model: model, source: source)
          },
          model_name: -> { recorder[:model_name] },
          model_key: -> { recorder[:model_key] },
          model_names: -> { recorder[:model_names] || model_names(recorder[:model_name]) },
          state_dir: -> { recorder[:state_dir] || Session.default_state_dir },
          scratch: -> { recorder[:scratch] },
          setup: -> { recorder[:setup] },
          prompt_files: -> { recorder[:prompt_files] },
          steer: ->(text, label) { recorder.steer(text, label) },
          stop_turn: ->(reason, label) { recorder.stop(:turn, reason, label) },
          stop_generation: ->(reason, label) { recorder.stop(:generation, reason, label) },
          frontend: -> { recorder[:frontend] },
          toolkit: -> { recorder[:toolkit] },
          declared_tools: -> { recorder[:declared_tools] || tool_names.call },
          use_toolkit: ->(name) { recorder.use_toolkit(name, toolkits.call) },
          load_tools: ->(names, bundle) { recorder.load_tools(names, bundle) },
          cancel_controller: ->(handler: false) { recorder[:cancelled] ? stopped : nil },
          cost: -> { cost(recorder[:cost]) },
          usage: -> { usage(recorder[:usage]) },
          turn_author: -> { recorder[:turn_author] },
          cache_confirm: lambda { |line, changed|
            CacheConfirm.ask(line: line, cost: :full, changed: changed,
                             engine: CacheEngine.new(recorder[:history], recorder[:context_tokens]))
          }
        )
      end

      # ctx.model_names for a model ref when the test sets none: the ref,
      # then its id without the host ("test:model" → test:model, model).
      def model_names(ref)
        ref = ref.to_s
        [ref, ref.split(":", 2).last].reject(&:empty?).uniq
      end

      # The parts a test may give bundle.set(cost: {...}).
      COST_PARTS = %i[reported estimated side known].freeze

      # The SessionMetrics::Cost ctx.cost returns for the recorder's +cost+
      # value (Recorder::DEFAULTS).
      # @return [SessionMetrics::Cost]
      def cost(value)
        value = value.call while value.respond_to?(:call)
        case value
        when nil then SessionMetrics::Cost.zero
        when SessionMetrics::Cost then value
        when Numeric then SessionMetrics::Cost.zero.with(reported: value.to_f)
        when Hash
          unknown = value.keys.map(&:to_sym) - COST_PARTS
          raise ArgumentError, "unknown cost parts: #{unknown.join(", ")}" unless unknown.empty?

          parts = value.transform_keys(&:to_sym)
          SessionMetrics::Cost.new(reported: parts.fetch(:reported, 0).to_f, estimated: parts.fetch(:estimated, 0).to_f,
                                   side: parts.fetch(:side, 0).to_f, known: parts.fetch(:known, true))
        else raise ArgumentError, "cost: a number, a Hash or a callable, not #{value.inspect}"
        end
      end

      # The parts a test may give bundle.set(usage: {...}).
      USAGE_PARTS = %i[turns tool_calls tool_calls_by_tool steps active_ms tool_ms_by_tool].freeze

      # The SessionMetrics::Usage ctx.usage returns for the recorder's
      # +usage+ value (Recorder::DEFAULTS): zeros for the parts not given;
      # tool_calls defaults to the sum of tool_calls_by_tool, active_ms to
      # the sum of tool_ms_by_tool.
      # @return [SessionMetrics::Usage]
      def usage(value)
        value = value.call while value.respond_to?(:call)
        case value
        when nil then SessionMetrics::Usage.zero
        when SessionMetrics::Usage then value
        when Hash
          parts = value.transform_keys(&:to_sym)
          unknown = parts.keys - USAGE_PARTS
          raise ArgumentError, "unknown usage parts: #{unknown.join(", ")}" unless unknown.empty?

          by_tool = parts.fetch(:tool_calls_by_tool, {}).transform_keys(&:to_s)
          ms_by_tool = parts.fetch(:tool_ms_by_tool, {}).transform_keys(&:to_s)
          SessionMetrics::Usage.new(turns: parts.fetch(:turns, 0), tool_calls: parts.fetch(:tool_calls, by_tool.values.sum),
                                    tool_calls_by_tool: by_tool, steps: parts.fetch(:steps, 0),
                                    active_ms: parts.fetch(:active_ms, ms_by_tool.values.sum), tool_ms_by_tool: ms_by_tool)
        else raise ArgumentError, "usage: a Hash or a callable, not #{value.inspect}"
        end
      end
    end

    # The hook runtime (Hooks::Runtime: event[:notify] and the other
    # helpers), recorded in the same Recorder as the Host.
    module Runtime
      module_function

      # @param recorder [Recorder]
      # @return [Hooks::Runtime]
      def build(recorder)
        Hooks::Runtime.new(
          notify: ->(text:, level:, hook:, fallback_for: nil) { recorder.notify(text, level, hook, fallback_for) },
          ask_user: ->(question) { recorder.ask_user(question) },
          stop_turn: ->(reason:, hook:) { recorder.stop(:turn, reason, hook) },
          steer: ->(text:, hook:) { recorder.steer(text, hook) },
          stop_generation: ->(reason:, hook:) { recorder.stop(:generation, reason, hook) },
          turn_author: -> { recorder[:turn_author] }
        )
      end
    end
  end
end
