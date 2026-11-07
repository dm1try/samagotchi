# frozen_string_literal: true

require_relative "degrade"

module Samagotchi
  # The one rule for handing a loop event to its on_stream_event callback
  # (KernelLoop#emit_stream_event, ToolRunner#emit): no callback is fine, and
  # a failing one (a UI gone) must not break the turn or the tool call. Its
  # failure is a Degrade record under :turn, named by the caller (+failure+,
  # so a log still says which side lost the event), with the event's type.
  module StreamEvent
    module_function

    # @param callback [#call, nil] the loop's on_stream_event
    # @param event [Hash] the event
    # @param failure [String] the Degrade event slug when +callback+ raises
    # @return the callback's value, nil when it raised or there is none
    def emit(callback, event, failure:)
      Degrade.call(:turn, failure, type: (event[:type] if event.is_a?(Hash))) { callback&.call(event) }
    end
  end
end
