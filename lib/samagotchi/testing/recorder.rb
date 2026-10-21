# frozen_string_literal: true

require_relative "../plugin/card"
require_relative "../plugin/context"
require_relative "../guardrails/parent_policy"
require_relative "../hook_question"

module Samagotchi
  module Testing
    # A line to the user (ctx.notify, event[:notify]); +hook+ is the
    # plugin's or hook file's label ("plugin.rb (bundle x)").
    Notice = Data.define(:text, :level, :hook, :fallback_for)
    # Text put into the running turn (ctx.steer, event[:steer]).
    Steer = Data.define(:text, :hook)
    # A ctx.load_tools call: the names given, and the bundle.
    ToolLoad = Data.define(:names, :bundle)
    # A stop_turn or stop_generation (+kind+ :turn or :generation).
    Stop = Data.define(:kind, :reason, :hook)
    # An ask_model request: the request Context built (SideQuestion), its
    # limits, cancel controller and the model: it named (nil: the session's;
    # the kit doesn't check it against any hosts), and +source+, the asking
    # bundle's name (what chi counts its side request under).
    ModelRequest = Data.define(:request, :timeout, :max_tokens, :cancel, :model, :source) do
      def initialize(source: nil, **) = super
    end

    # What a bundle did at chi's edges, for a test to read: the Engine side
    # of its Context (Testing::Host) and the hook runtime (Testing::Runtime)
    # land here, file hooks and plugin hooks in the same lists. It also
    # holds what those edges answer: queued ask_user / ask_model answers and
    # the session's values (#values), read at each call.
    class Recorder
      # The session values a Host reads when the test sets none.
      DEFAULTS = {
        session_id: "test-session", cwd: nil, messages: [], messages_partial: false, model_name: "test:model",
        model_key: "model", toolkit: "full", declared_tools: nil, frontend: :worker, scratch: false, setup: nil,
        prompt_files: [], cancelled: false, state_dir: nil, running: true, toolkit_staged: true, load_tools_staged: nil,
        # ctx.cost: nil (zero), a Float (reported USD), a Hash of the parts
        # (reported:, estimated:, side:, known:) or a callable giving one.
        cost: nil
      }.freeze

      attr_reader :notices, :cards, :steers, :stops, :questions, :model_requests, :toolkit_uses, :tool_loads, :answers,
                  :model_answers, :values

      def initialize(**values)
        unknown = values.keys - DEFAULTS.keys
        raise ArgumentError, "unknown host values: #{unknown.join(", ")}" unless unknown.empty?

        @values = DEFAULTS.merge(values)
        @notices = []
        @cards = []
        @steers = []
        @stops = []
        @questions = []
        @model_requests = []
        @toolkit_uses = []
        @tool_loads = []
        @answers = []
        @model_answers = []
        @mutex = Mutex.new
      end

      # Change session values (cwd:, messages:, running:, cancelled: …).
      def set(**values)
        unknown = values.keys - DEFAULTS.keys
        raise ArgumentError, "unknown host values: #{unknown.join(", ")}" unless unknown.empty?

        @mutex.synchronize { @values.merge!(values) }
        self
      end

      def [](key) = @mutex.synchronize { @values.fetch(key) }

      # Only stop_turn's, or only stop_generation's.
      def turn_stops = stops.select { |stop| stop.kind == :turn }
      def generation_stops = stops.select { |stop| stop.kind == :generation }

      def notify(text, level, hook, fallback_for)
        record(@notices, Notice.new(text: text.to_s, level: level, hook: hook, fallback_for: fallback_for))
        nil
      end

      # Checked as chi's cards are (Plugin::Card.build); the id it shows.
      def card(**fields)
        card = Plugin::Card.build(**fields).freeze
        record(@cards, card)
        card[:id]
      end

      def steer(text, hook)
        return false unless self[:running]

        record(@steers, Steer.new(text: text.to_s, hook: hook))
        true
      end

      def stop(kind, reason, hook)
        return false unless self[:running]

        record(@stops, Stop.new(kind: kind, reason: reason.to_s, hook: hook))
        true
      end

      # The next queued answer (#answers), nil with none (no one to ask).
      # Effects chi would refuse (a label the options don't have, an
      # unknown effect: Guardrails::ParentPolicy.option_tags) ask no one, as
      # in chi: nil, nothing recorded, no answer taken.
      # @param question [HookQuestion] recorded as asked (#questions; its
      #   effects as the bundle gave them: label => effect, nil for none)
      def ask_user(question)
        return nil if Guardrails::ParentPolicy.option_tags(question.options, question.effects) == false

        record(@questions, question)
        answer = @mutex.synchronize { @answers.shift }
        answer.respond_to?(:call) ? answer.call(@questions.last) : answer
      end

      # The next queued model answer (#model_answers): a String, an
      # exception to raise, or a callable given the ModelRequest. None left:
      # Plugin::ModelError, as an unreachable model.
      def ask_model(request, timeout:, max_tokens:, cancel_controller:, model: nil, source: nil)
        entry = ModelRequest.new(request: request, timeout: timeout, max_tokens: max_tokens, cancel: cancel_controller,
                                 model: model, source: source)
        record(@model_requests, entry)
        answer = @mutex.synchronize { @model_answers.empty? ? :none : @model_answers.shift }
        raise Plugin::ModelError, "no model answer queued (bundle.model_answers << \"text\")" if answer == :none
        raise answer if answer.is_a?(Exception) || (answer.is_a?(Class) && answer <= Exception)

        answer.respond_to?(:call) ? answer.call(entry) : answer
      end

      # ctx.load_tools: recorded; every name is staged unless the test set
      # load_tools_staged: (a list: those only).
      def load_tools(names, bundle)
        record(@tool_loads, ToolLoad.new(names: names, bundle: bundle))
        staged = self[:load_tools_staged]
        staged ? names & Array(staged) : names
      end

      # ctx.use_toolkit: +known+ the toolkits chi and the plugins declare.
      # Staged (toolkit_staged:, true by default), the session is on it at
      # once, as chi saves it on the session (ToolkitBinding#use).
      def use_toolkit(name, known)
        raise ArgumentError, "no toolkit named #{name}" unless known.include?(name)

        record(@toolkit_uses, name)
        return false unless self[:toolkit_staged]

        set(toolkit: name)
        true
      end

      private

      def record(list, item)
        @mutex.synchronize { list << item }
      end
    end
  end
end
