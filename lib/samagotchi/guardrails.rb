# frozen_string_literal: true

require_relative "guardrails/verdict"
require_relative "guardrails/context"
require_relative "guardrails/targets"
require_relative "guardrails/gate"

module Samagotchi
  # Tool guardrails: the verdict every model tool call gets before it is
  # dispatched. ToolRunner asks the Gate; hooks and rules vote.
  module Guardrails
  end
end
