# frozen_string_literal: true

require "time"
require_relative "push"

module Samagotchi
  module Web
    # The owner's Web Push routes (App::ROUTES, all :owner rows: a
    # participant gets no pushes): what the page's bell asks (GET /api/push),
    # subscribing this device and unsubscribing it, and a test push.
    # Included in App: its helpers (json_response, error_response,
    # parse_json, request_body) and @push (a Push::Runtime, nil when push is
    # off: no https public_url, or web.push.enabled false) answer. See
    # docs/internals/web-push.md.
    module PushRoutes
      PUSH_BODY_LIMIT = 8192

      private

      # {enabled, public_key, origin, this}: +this+ is the device whose
      # endpoint the page sends as ?endpoint= (its pushManager's), nil when
      # this store doesn't have it for this origin.
      def handle_push_info(req)
        return json_response(200, { enabled: false, public_key: nil, origin: nil, this: nil }) unless @push

        endpoint = req.params["endpoint"].to_s
        this = endpoint.empty? ? nil : @push.store.for_origin(@push.origin).find { |sub| sub.endpoint == endpoint }
        json_response(200, { enabled: true, public_key: Push::Crypto.public_key_b64(@push.store.vapid_key),
                             origin: @push.origin, this: this && { id: this.id, label: this.label } })
      end

      # {subscription: {endpoint, keys: {p256dh, auth}}, replaces?: id} →
      # 201 {id, label}. +replaces+ is the id this device was given before
      # (the page keeps it): that entry goes (Store#add).
      def handle_push_subscribe(req)
        return push_off unless @push

        body = push_body(req)
        return error_response(400, "invalid_json", "invalid JSON body") unless body.is_a?(Hash)

        sub = @push.store.add(body["subscription"], origin: @push.origin, label: device_label(req),
                                                    replaces: body["replaces"]) do |old|
          Log.info(:web, "push_replaced", device: old.id)
        end
        Log.info(:web, "push_subscribed", device: sub.id)
        json_response(201, { id: sub.id, label: sub.label })
      rescue Push::Store::Invalid => e
        error_response(400, "invalid_subscription", e.message)
      end

      # {endpoint} → 204: this device's bell turned off.
      def handle_push_unsubscribe(req)
        return push_off unless @push

        body = push_body(req)
        endpoint = body["endpoint"] if body.is_a?(Hash)
        return error_response(400, "missing_fields", "endpoint is required") unless endpoint.is_a?(String) && !endpoint.empty?

        gone = @push.store.remove(endpoint)
        Log.info(:web, "push_unsubscribed", device: gone.id) if gone
        [204, { "Cache-Control" => "no-store" }, []]
      end

      # {endpoint?} → a test push to that device (or every one on this
      # origin), answered with each device's result.
      def handle_push_test(req)
        return push_off unless @push

        body = push_body(req)
        endpoint = body["endpoint"] if body.is_a?(Hash)
        subs = @push.store.for_origin(@push.origin)
        subs = subs.select { |sub| sub.endpoint == endpoint } if endpoint.is_a?(String) && !endpoint.empty?
        payload = { v: 1, kind: "show", tag: "chi:test", title: "chi", body: "test notification", url: "/" }
        results = subs.map do |sub|
          result = @push.client.deliver(sub, payload, ttl: 600, urgency: "high")
          Log.info(:web, "push_test", device: sub.id, code: result.code, ms: result.ms)
          @push.store.remove(sub.id) if result.status == :gone
          { id: sub.id, label: sub.label, status: result.status.to_s, code: result.code, ms: result.ms }
        end
        json_response(200, { devices: results })
      end

      def push_off
        error_response(409, "push_off", "push needs an https public URL (chi web --tunnel tailscale, or web.public_url) " \
                                        "and web.push.enabled")
      end

      def push_body(req) = parse_json(request_body(req, PUSH_BODY_LIMIT))

      # chi's own name for the device (a subscription carries none): its
      # class from the User-Agent (iOS's is frozen, so it is generic) and
      # the date.
      def device_label(req)
        agent = req.get_header("HTTP_USER_AGENT").to_s
        kind = if agent.include?("iPhone") then "iPhone"
               elsif agent.include?("iPad") then "iPad"
               elsif agent.include?("Macintosh") then "Mac"
               else "Browser"
               end
        "#{kind} · #{Time.now.strftime("%Y-%m-%d")}"
      end
    end
  end
end
