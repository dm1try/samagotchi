# frozen_string_literal: true

require_relative "../log"
require_relative "../worker_link"

module Samagotchi
  module Web
    # POST /api/sessions/:id/reload_check, mixed into App: the opt-in reload
    # check's report (web.reload_check; the page's reload_check.js compares a
    # finished turn as it was drawn live with a reload of it, history_shape.js).
    # One log line per check, counts only, never content: reload_checked,
    # and reload_mismatch with the kinds that differed and the ACCEPTED
    # entries that would excuse them (the page's check is strict). The pod count is
    # `grep -c reload_mismatch` over `grep -c reload_checked`, split by
    # kinds, drawn and worker_version. See docs/configuration.md.
    module ReloadCheckRoute
      # history_shape.js KINDS: the only tokens a kinds list may carry
      # (spec/web/reload_check_route_spec.rb reads the JS list).
      KINDS = %w[prompt steered note command recap block step steer row notice card question thinking answer
                 empty-answer timing cancel failed other].freeze
      # history_shape.js ACCEPTED's ids: the only tokens an excused list may
      # carry (the same spec reads the JS list).
      ACCEPTED_IDS = %w[retry-row command-bubble edit-mark failed-step in-turn-card].freeze
      # A turn id the line may name (a uuid, a test's id); anything else is
      # dropped.
      TURN_ID = /\A[0-9A-Za-z_-]{1,64}\z/

      private

      # {turn_id, same, kinds, excused, explained, drawn} from the page: 204,
      # whatever it said
      # (fire-and-forget); 400 for a body that isn't a JSON object.
      # worker_version is chi web's own view of the session's worker (its
      # sidecar), never the body's.
      def handle_reload_check(req, id)
        body = parse_json(request_body(req, 4096))
        return error_response(400, "invalid_json", "invalid JSON body") unless body.is_a?(Hash)

        turn_id = body["turn_id"].to_s.match?(TURN_ID) ? body["turn_id"] : nil
        same = body["same"] == true
        drawn = body["drawn"] == true
        fields = { sid: id, turn_id: turn_id, same: same, drawn: drawn, worker_version: checked_worker_version(id) }
        Log.info(:web, "reload_checked", **fields)
        unless same
          Log.info(:web, "reload_mismatch", **fields.except(:same), kinds: checked_tokens(body["kinds"], KINDS),
                                                                   excused: checked_tokens(body["excused"], ACCEPTED_IDS),
                                                                   explained: body["explained"] == true)
        end
        [204, { "Cache-Control" => "no-store" }, []]
      end

      # +tokens+ as a sorted comma list of +known+'s, the rest dropped.
      def checked_tokens(tokens, known)
        Array(tokens).map(&:to_s).select { |token| known.include?(token) }.uniq.sort.join(",")
      end

      # The version of the chi the session's live worker runs (its
      # sidecar), nil without one.
      def checked_worker_version(id)
        dir = @session_class.session_dir(id, state_dir: default_state_dir)
        link = WorkerLink.resolve(dir, unlink: false)
        link.live? ? link.sidecar&.version : nil
      rescue StandardError
        nil # degrade-ok: a line without the version is still counted
      end
    end
  end
end
