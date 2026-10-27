# frozen_string_literal: true

require "json"
require_relative "chi_invocation"

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

    module_function

    # What every client shows when a worker refuses its secret.
    def refused(session_id, via: ChiInvocation::HERE)
      web = via.remote? ? via.web : "chi web"
      "session #{session_id}'s worker refused this chi's request (it didn't name its secret): a chi web or " \
        "terminal started before chi was updated can't reach it; restart #{web}, re-attach with " \
        "#{via.attach(session_id)}, or restart the worker with #{via.command("sessions restart #{session_id}")}"
    end

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
