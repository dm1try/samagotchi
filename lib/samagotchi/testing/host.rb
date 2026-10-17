# frozen_string_literal: true

require_relative "../cancellation_controller"
require_relative "../plugin/context"
require_relative "recorder"

module Samagotchi
  module Testing
    # The Engine side of a bundle's Context, recorded: a real Plugin::Host
    # with every member set, its values read from the Recorder at each call
    # and its actions landing in it.
    module Host
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
          ask_user: lambda { |question:, options:, header:, allow_freeform:, hook:|
            recorder.ask_user(question: question, options: options, header: header, allow_freeform: allow_freeform, hook: hook)
          },
          cancelled: -> { recorder[:cancelled] },
          card: ->(**card) { recorder.card(**card) },
          ask_model: lambda { |request, timeout:, max_tokens:, cancel_controller:, model: nil|
            recorder.ask_model(request, timeout: timeout, max_tokens: max_tokens, cancel_controller: cancel_controller,
                                        model: model)
          },
          model_name: -> { recorder[:model_name] },
          model_key: -> { recorder[:model_key] },
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
          cancel_controller: ->(handler: false) { recorder[:cancelled] ? stopped : nil }
        )
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
          ask_user: lambda { |question:, options:, header:, allow_freeform:, hook:|
            recorder.ask_user(question: question, options: options, header: header, allow_freeform: allow_freeform, hook: hook)
          },
          stop_turn: ->(reason:, hook:) { recorder.stop(:turn, reason, hook) },
          steer: ->(text:, hook:) { recorder.steer(text, hook) },
          stop_generation: ->(reason:, hook:) { recorder.stop(:generation, reason, hook) }
        )
      end
    end
  end
end
