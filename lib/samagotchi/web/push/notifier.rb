# frozen_string_literal: true

require "json"
require_relative "attention"
require_relative "../../log"

module Samagotchi
  module Web
    module Push
      # chi web's one sender of pushes: a SessionHub subscriber that keeps
      # the summaries the page's trackAttention keeps (seeded by the
      # subscribe's snapshot, so what was open before never pushes), turns
      # each new approval or question (Attention.for) into a show, and
      # hands it to its own sender thread through a Queue; one answered
      # anywhere (Attention.closed_keys) only cancels its show's hold.
      #
      # Every push it sends shows a notification: WebKit removes a
      # subscription after a few pushes that show none (its silent-push
      # quota), so there is no close push. A show carries +open+, the keys
      # still open, and the badge, both from the sink's summaries
      # (Attention.open_keys): the service worker closes the answered ones
      # when it shows the new one, and the page when it opens.
      #
      # #call is the hub's sink: it runs under the hub's Monitor, on the
      # tick thread and on chi web's request threads (SessionHub#touch), so
      # it only enqueues; a push is a 0.5 s https call, made on the sender
      # thread. There a show waits its hold (HOLD, or the event's own) and
      # is pushed only while still open, to every device subscribed on this
      # run's public origin. See docs/internals/web-push.md.
      class Notifier
        HOLD = 3.0
        # Waiting kinds: kept 12 h for an offline phone, delivered at once.
        SHOW_TTL = 12 * 3600
        # A show carries +open+ only while its JSON stays this small: one
        # aes128gcm record leaves 3993 bytes of plaintext under Web Push's
        # 4096 (86 header, 1 delimiter, 16 tag). Longer, it goes without
        # (and the worker cleans up nothing).
        OPEN_LIMIT = 3000
        STOP_JOIN = 2.0

        Show = Data.define(:attention, :title, :body, :at)
        Close = Data.define(:keys)

        # @param store [Store] the devices (and the key the client signs with)
        # @param client [#deliver] Client
        # @param origin [String] this run's public origin: only the
        #   subscriptions made on it are sent to
        # @param now [#call] monotonic seconds (specs move it)
        def initialize(store:, client:, origin:, hold: HOLD, now: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @store = store
          @client = client
          @origin = origin
          @hold = hold
          @now = now
          @queue = Queue.new
          # The sink's side (under @mutex): the last summary per session.
          @mutex = Mutex.new
          @by_id = {}
          @seeded = false
          @early = []
          # The sender's side (its thread only, or #pump in a spec).
          @pending = {} # key → Show waiting its hold
          @refused = false
          @thread = nil
          @handle = nil
        end

        # Subscribes to +hub+ (its snapshot is the seed) and starts the
        # sender thread. Call it after a hub.scan, or the snapshot is empty
        # and the first scan's events push every open approval.
        # @param sender [Boolean] false: no thread, a spec drives #pump
        def start(hub, sender: true)
          @handle, summaries = hub.subscribe(self, snapshot: true)
          seed(summaries)
          @thread = Thread.new { run } if sender
          self
        end

        # Unsubscribes and ends the sender thread; holds still waiting are
        # dropped, a push in flight may finish (joined with a timeout).
        def stop
          @handle&.unsubscribe
          @handle = nil
          @queue << :stop
          @thread&.join(STOP_JOIN)
          @thread = nil
          nil
        end

        # The hub's sink (SessionHub::Event): never blocks.
        def call(event)
          @mutex.synchronize do
            next @early << event unless @seeded

            notice(event)
          end
        end

        # The seed: the summaries as the subscribe saw them. Events that came
        # before it (newer than the snapshot) are applied after it.
        def seed(summaries)
          @mutex.synchronize do
            summaries.each { |summary| @by_id[summary[:id]] = summary if summary[:id] }
            @seeded = true
            @early.each { |event| notice(event) }
            @early.clear
          end
        end

        # What is queued, handled now, then the shows whose hold is up
        # pushed; the sender thread's step (specs call it with no thread).
        def pump
          loop do
            message = @queue.pop(true)
            return if message == :stop

            handle(message)
          rescue ThreadError
            break
          end
          flush
        end

        private

        def notice(event)
          case event.type
          when "session"
            summary = event.data[:session]
            return unless summary.is_a?(Hash) && summary[:id]

            prev = @by_id[summary[:id]]
            @by_id[summary[:id]] = summary
            keys = Attention.closed_keys(prev, summary)
            @queue << Close.new(keys: keys) unless keys.empty?
            attention = Attention.for(prev, summary)
            enqueue_show(attention, summary) if attention
          when "session_gone"
            prev = @by_id.delete(event.data[:id])
            keys = Attention.closed_keys(prev, nil)
            @queue << Close.new(keys: keys) unless keys.empty?
          end
        end

        def enqueue_show(attention, summary)
          title, body = Attention.text(summary, attention.reason)
          @queue << Show.new(attention: attention, title: title, body: body, at: @now.call)
        end

        def run
          loop do
            due = @pending.values.map { |show| due_at(show) }.min
            wait = due && [due - @now.call, 0].max
            message = @queue.pop(timeout: wait)
            break if message == :stop

            handle(message) if message
            flush
          rescue StandardError => e
            Log.exception(:web, "push_sender_failed", e)
          end
        end

        def handle(message)
          case message
          when Show then @pending[message.attention.key] = message
          # Answered anywhere: a show still in its hold is dropped. Nothing
          # is pushed (a push that shows nothing counts against the quota).
          when Close then message.keys.each { |key| @pending.delete(key) }
          end
        end

        def due_at(show) = show.at + (show.attention.hold || @hold)

        def flush
          now = @now.call
          due = @pending.values.select { |show| due_at(show) <= now }
          return if due.empty?

          due.each { |show| @pending.delete(show.attention.key) }
          open = @mutex.synchronize { Attention.open_keys(@by_id) }
          due.each do |show|
            key = show.attention.key
            next unless open.include?(key)

            deliver(show_payload(show, open), kind: show.attention.reason)
          end
        end

        def show_payload(show, open)
          payload = { v: 1, kind: "show", tag: show.attention.key, title: show.title, body: show.body,
                      url: "/#/s/#{show.attention.session_id}", badge: open.size }
          with_open = payload.merge(open: open)
          JSON.generate(with_open).bytesize <= OPEN_LIMIT ? with_open : payload
        end

        # @param kind [String] the reason, for the log line
        # @return [Boolean] whether any device took it
        def deliver(payload, kind:)
          return false if @refused

          @store.for_origin(@origin).map do |sub|
            result = @client.deliver(sub, payload, ttl: SHOW_TTL, urgency: "high")
            record(sub, result, kind)
            result.ok?
          end.any?
        end

        def record(sub, result, kind)
          fields = { device: sub.id, code: result.code, ms: result.ms, kind: kind }
          case result.status
          when :ok
            Log.info(:web, "push_sent", **fields)
            @store.mark(sub.id, ok: true)
          when :gone
            Log.info(:web, "push_gone", **fields)
            @store.remove(sub.id)
          when :bad_jwt
            @refused = true
            Log.warn(:web, "push_bad_jwt", echo: "[chi web] the push service refused chi's VAPID token: check " \
                                                 "web.push.contact (no pushes until chi web restarts)", **fields)
          else
            Log.warn(:web, "push_failed", error: result.error, **fields)
            @store.mark(sub.id, error: result.error)
          end
        end
      end
    end
  end
end
