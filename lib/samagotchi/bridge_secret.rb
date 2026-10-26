# frozen_string_literal: true

require "json"

module Samagotchi
  # A session Bridge's secret, as both sides name it: the request header
  # that carries it (Bridge#secret_ok?, BridgeClient), the error a Bridge
  # answers without it (403), and the one message every client shows for
  # that refusal.
  module BridgeSecret
    # The request header (Bridge's #read_request keeps names lowercased).
    HEADER = "X-Chi-Bridge"
    # The 403's error.
    ERROR = "bridge_secret"
    # What a request without this Bridge's secret, or with another one, is
    # told, and what a client shows when it gets that: the asker comes from
    # a chi that reads no secret, a chi web, an attached terminal or a
    # session worker (a delegate's parent) started before chi was updated.
    REFUSED = "the request didn't name this session worker's secret: a chi web, an attached terminal or a session " \
              "worker started before chi was updated can't reach it; restart chi web, re-attach terminals " \
              "(chi --attach ID) and restart the older session workers (chi sessions restart ID...)"

    module_function

    # Whether a Bridge reply (+status+, raw +body+) is this refusal.
    def refused?(status, body)
      return false unless status.to_i == 403

      parsed = body.is_a?(Hash) ? body : JSON.parse(body.to_s)
      parsed.is_a?(Hash) && parsed["error"] == ERROR
    rescue JSON::ParserError
      false
    end
  end
end
