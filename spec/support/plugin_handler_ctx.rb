# frozen_string_literal: true

# For a bundle spec's fake ctx: inside a handler (#with_event) ctx.notify,
# ask_user, steer, stop_turn and stop_generation go to the fired event's
# own helper when the spec put one on it, as Plugin::Context does with the
# registry's (spec/samagotchi/plugin/current_event_spec.rb); otherwise the
# fake's own method (the anytime path). Prepend it to the fake's class.
module PluginHandlerCtx
  HELPERS = %i[notify ask_user steer stop_turn stop_generation].freeze

  def with_event(event)
    previous = @current_event
    @current_event = event
    yield
  ensure
    @current_event = previous
  end

  HELPERS.each do |name|
    define_method(name) do |*args, **kwargs|
      helper = @current_event.is_a?(Hash) ? @current_event[name] : nil
      next helper.call(*args, **kwargs) if helper

      super(*args, **kwargs)
    end
  end
end
