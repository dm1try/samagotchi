# frozen_string_literal: true

require "time"
require_relative "push"

module Samagotchi
  module Web
    # The owner's Web Push routes (App::ROUTES, all :owner rows: a
    # participant gets no pushes): what the page's bell asks (GET /api/push),
    # subscribing this device and unsubscribing it, a test push, and the
    # pages' presence (no push while the owner looks at one).
    # Included in App: its helpers (json_response, error_response,
    # parse_json, request_body) and @push (a Push::Runtime, nil when push is
    # off: no https public_url, or web.push.enabled false) answer. See
    # docs/internals/web-push.md.
    module PushRoutes
      PUSH_BODY_LIMIT = 8192

      private

      # {enabled, public_key, origin, this, devices, stale}: +this+ is the
      # device whose endpoint the page sends as ?endpoint= (its
      # pushManager's), nil when this store doesn't have it for this
      # origin; +devices+ this origin's (Sub#public_h, +this+ marked),
      # +stale+ how many were made on another origin (never sent to).
      def handle_push_info(req)
        return json_response(200, { enabled: false, public_key: nil, origin: nil, this: nil }) unless @push

        endpoint = req.params["endpoint"].to_s
        subs = @push.store.subscriptions
        mine = subs.select { |sub| sub.origin == @push.origin }
        this = endpoint.empty? ? nil : mine.find { |sub| sub.endpoint == endpoint }
        json_response(200, { enabled: true, public_key: Push::Crypto.public_key_b64(@push.store.vapid_key),
                             origin: @push.origin, this: this && { id: this.id, label: this.label },
                             devices: mine.map { |sub| sub.public_h.merge(this: sub.equal?(this)) },
                             stale: subs.size - mine.size })
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

      # PATCH …/subscriptions/ID {prefs: {done: true|false}} → 200 the
      # device (Sub#public_h): whether it gets a push for a long turn done.
      def handle_push_prefs(req, id)
        return push_off unless @push

        body = push_body(req)
        prefs = body["prefs"] if body.is_a?(Hash)
        unless prefs.is_a?(Hash) && prefs.keys == ["done"] && [true, false].include?(prefs["done"])
          return error_response(400, "invalid_prefs", "give {prefs: {done: true|false}}")
        end

        sub = Push::Store.short_id?(id) && @push.store.set_prefs(id, done: prefs["done"], origin: @push.origin)
        return unknown_device(id) unless sub

        Log.info(:web, "push_prefs", device: sub.id, done: sub.done?)
        json_response(200, sub.public_h)
      end

      # DELETE …/subscriptions/ID → 204: the devices list's Remove for
      # another device (this device's row turns the bell off instead, so
      # the page and the store agree).
      def handle_push_remove(_req, id)
        return push_off unless @push

        sub = Push::Store.short_id?(id) && @push.store.remove_device(id, origin: @push.origin)
        return unknown_device(id) unless sub

        Log.info(:web, "push_removed", device: sub.id)
        [204, { "Cache-Control" => "no-store" }, []]
      end

      # {endpoint} → 204: this device's bell turned off (only a device
      # subscribed on this origin, as the other device routes).
      def handle_push_unsubscribe(req)
        return push_off unless @push

        body = push_body(req)
        endpoint = body["endpoint"] if body.is_a?(Hash)
        return error_response(400, "missing_fields", "endpoint is required") unless endpoint.is_a?(String) && !endpoint.empty?

        gone = @push.store.remove(endpoint, origin: @push.origin)
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
        results = subs.map do |sub|
          result = @push.client.deliver(sub, Push::TEST_PAYLOAD, ttl: Push::TEST_TTL, urgency: "high")
          Log.info(:web, "push_test", device: sub.id, code: result.code, ms: result.ms)
          @push.store.remove(sub.id) if result.status == :gone
          { id: sub.id, label: sub.label, status: result.status.to_s, code: result.code, ms: result.ms }
        end
        json_response(200, { devices: results })
      end

      # {page, front} → 204: whether the user is at this page (visible,
      # focused, touched lately; notifications.js reports it). Also with
      # push off: a desk tab has nothing to be told.
      def handle_push_presence(req)
        page, front = Push::Presence.parse(push_body(req))
        return error_response(400, "invalid_presence", "give {page: id, front: true|false}") unless page

        @push&.presence&.report(page, front)
        [204, { "Cache-Control" => "no-store" }, []]
      end

      def unknown_device(id) = error_response(404, "unknown_device", "no device #{id[0, 16]} pushes from this origin")

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
