# frozen_string_literal: true

require_relative "system_one/errors"
require_relative "system_one/question"
require_relative "system_one/answer"
require_relative "system_one/fake_backend"
require_relative "system_one/http_backend"
require_relative "system_one/client"
require_relative "system_one/log"
require_relative "system_one/approval_question"

module Samagotchi
  # System 1: the cheap judgment model that will, one phase at a time,
  # answer the guardrail asks a user always allows. P1 is the client and its
  # settings; P2a judges every ask a user is about to see and logs the
  # judgment and their answer (SystemOne::Log). Nothing about the ask changes
  # yet — the auto-allow is P3 (docs/guardrails.md, "System 1").
  module SystemOne
  end
end
