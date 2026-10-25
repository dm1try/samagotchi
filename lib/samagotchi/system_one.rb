# frozen_string_literal: true

require_relative "system_one/errors"
require_relative "system_one/question"
require_relative "system_one/answer"
require_relative "system_one/fake_backend"
require_relative "system_one/http_backend"
require_relative "system_one/client"

module Samagotchi
  # System 1: the cheap judgment model that will, one phase at a time,
  # answer the guardrail asks a user always allows. P1 is the client and its
  # settings only — nothing judges yet (docs/guardrails.md, "System 1").
  module SystemOne
  end
end
