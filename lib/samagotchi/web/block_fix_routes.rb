# frozen_string_literal: true

require_relative "../block_fix"
require_relative "request_body"

module Samagotchi
  module Web
    # POST /api/sessions/:id/blocks/fix {turn_id, lang, source, reason},
    # mixed into App: the owner's page asks again, once, for a block it
    # couldn't draw in the newest answer, relayed to the worker's Bridge
    # (Bridge::BlockFixRoute; docs/internals/block-renderers.md, A failed
    # block is asked for again). With web.block_fix off it answers 404, as
    # an unknown route.
    module BlockFixRoutes
      # The worker's answers passed through as they are; any other is 502.
      PASSED = [200, 202].freeze
      REFUSED = [400, 409, 413, 429].freeze

      private

      def handle_block_fix(req, id)
        return not_found(path: req.path) unless @block_fix == "auto"

        body = parse_json(request_body(req, RequestBody::SMALL_BODY_LIMIT))
        return error_response(400, "invalid_json", "invalid JSON body") unless body.is_a?(Hash)

        fields = body.slice("turn_id", "lang", "source", "reason").transform_keys(&:to_sym)
        request = ->(client) { client.fix_block(turn_id: nil, lang: nil, source: nil, reason: nil, **fields) }
        relay(id, bridge_client(id), request, what: "the fix was not asked for", cant: "fix blocks") do |reply|
          if PASSED.include?(reply.status)
            json_response(reply.status, reply.json || {})
          elsif REFUSED.include?(reply.status)
            error_response(reply.status, reply.json&.dig("error") || "refused", reply_detail(reply, "the fix was refused"))
          end
        end
      end
    end
  end
end
