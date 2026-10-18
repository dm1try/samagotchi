# frozen_string_literal: true

class Plugin
  def initialize(settings) = @word = settings.fetch("word", "hello")

  def register(chi)
    chi.command("/greet", "greets") { |_args, ctx| ctx.notify(@word) }
    chi.on(:after_tool_call) { |_event, _ctx| nil }
  end
end
