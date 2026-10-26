# frozen_string_literal: true

require "json"
require "uri"
require "time"
require_relative "attention"
require_relative "../../log"

module Samagotchi
  module Web
    module Push
      # chi web's one sender of pushes: a SessionHub subscriber that keeps
      # the summaries the page's trackAttention keeps (seeded by the
      # subscribe's snapshot, so what was open before never pushes), turns
      # each new attention (Attention.for: a question, an approval, a
      # step-limit continue, a card with actions, a failed or done turn)
      # into a show, and hands it to its own sender thread through a Queue;
      # one answered anywhere (Attention.closed_keys) only cancels its
      # show's hold.
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
      # is pushed, a waiting one only while still open, to the devices
      # subscribed on this run's public origin (a done turn only to those
      # that asked for it), unless a chi web page is in front (Presence):
      # then the owner is looking, and the key is never pushed. At most CAP
      # shows an hour; a 429 or 5xx is retried once (Client::Result
      # #retry_after) without the sender ever sleeping. Each key handled
      # (pushed, skipped or capped) goes in the store's sent.json, so after
      # a restart the seed pushes an approval asked meanwhile (open, under
      # CATCH_UP old) and nothing pushed already. See
      # docs/internals/web-push.md.
      class Notifier
        HOLD = 3.0
        # Waiting kinds: kept 12 h for an offline phone, delivered at once.
        SHOW_TTL = 12 * 3600
        # A failed or done turn: stale soon, no need to wake the phone.
        EVENT_TTL = 600
        # A show carries +open+ only while its JSON stays this small: one
        # aes128gcm record leaves 3993 bytes of plaintext under Web Push's
        # 4096 (86 header, 1 delimiter, 16 tag). Longer, it goes without
        # (and the worker cleans up nothing).
        OPEN_LIMIT = 3000
        STOP_JOIN = 2.0
        # Shows (one event, however many devices) per rolling CAP_WINDOW.
        CAP = 30
        CAP_WINDOW = 3600
        # A question open at a restart is pushed if it was asked this
        # recently and isn't in sent.json.
        CATCH_UP = 3600

        # url: the page the notification opens (Notifier.session_url).
        Show = Data.define(:attention, :title, :body, :at, :url)
        Close = Data.define(:keys)
        # One device's show, again at +at+ (the push service said when).
        Retry = Data.define(:show, :sub_id, :at)

        # The page a session's notification opens: the session in its own
        # project's view (?dir=<its project root>), or in the all view
        # (?scope=all) for a session in no repo, never chi web's bare page
        # (its start folder's project). The service worker navigates an open
        # window to it, query and all.
        def self.session_url(summary)
          root = summary[:project_root]
          scope = root ? "dir=#{URI.encode_www_form_component(root).gsub("%2F", "/")}" : "scope=all"
          "/?#{scope}#/s/#{summary[:id]}"
        end

        # @param store [Store] the devices (and the key the client signs with)
        # @param client [#deliver] Client
        # @param origin [String] this run's public origin: only the
        #   subscriptions made on it are sent to
        # @param presence [Presence, nil] the pages' reports (nil: nobody is
        #   ever in front)
        # @param now [#call] monotonic seconds (specs move it)
        # @param clock [#call] the Time now (a question's created_at)
        def initialize(store:, client:, origin:, presence: nil, hold: HOLD,
                       now: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, clock: -> { Time.now })
          @store = store
          @client = client
          @origin = origin
          @presence = presence
          @hold = hold
          @now = now
          @clock = clock
          @queue = Queue.new
          # The sink's side (under @mutex): the last summary per session.
          @mutex = Mutex.new
          @by_id = {}
          @seeded = false
          @early = []
          # The sender's side (its thread only, or #pump in a spec).
          @pending = {} # key → Show waiting its hold
          @retries = {} # [key, device id] → Retry
          @shown = [] # when each counted show went, oldest first
          @capped_warned_at = nil
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
        # before it (newer than the snapshot) are applied after it. An open
        # question asked under CATCH_UP ago that no earlier run handled
        # (sent.json) is shown: it came while chi web was down.
        def seed(summaries)
          @mutex.synchronize do
            summaries.each { |summary| @by_id[summary[:id]] = summary if summary[:id] }
            catch_up(summaries)
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

        # Cards carry no time: they seed as they are.
        def catch_up(summaries)
          sent = nil
          at = @clock.call
          summaries.each do |summary|
            question = summary[:pending_question]
            next unless summary[:id] && question.is_a?(Hash) && question[:id] && !question[:relayed_to]

            asked = asked_at(question[:created_at])
            next unless asked && at - asked < CATCH_UP

            sent ||= @store.sent_keys
            attention = Attention.for(nil, summary)
            next if attention.nil? || sent.key?(attention.key)

            Log.info(:web, "push_catch_up", kind: attention.reason)
            enqueue_show(attention, summary)
          end
        end

        def asked_at(text)
          text.is_a?(String) ? Time.iso8601(text) : nil
        rescue ArgumentError
          nil
        end

        def enqueue_show(attention, summary)
          title, body = Attention.text(summary, attention.reason)
          @queue << Show.new(attention: attention, title: title, body: body, at: @now.call,
                             url: Notifier.session_url(summary))
        end

        def run
          loop do
            due = (@pending.values.map { |show| due_at(show) } + @retries.values.map(&:at)).min
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
          retries = @retries.values.select { |again| again.at <= now }
          return if due.empty? && retries.empty?

          due.each { |show| @pending.delete(show.attention.key) }
          retries.each { |again| @retries.delete([again.show.attention.key, again.sub_id]) }
          open = @mutex.synchronize { Attention.open_keys(@by_id) }
          due.each { |show| send_show(show, open) if still_due?(show, open) }
          retries.each { |again| send_retry(again, open) if still_due?(again.show, open) }
        end

        # A waiting show while its key is open; a failed or done turn's as
        # is (nothing to answer).
        def still_due?(show, open) = !Attention.waiting?(show.attention.reason) || open.include?(show.attention.key)

        # A due show to its devices, unless a page is in front (the in-tab
        # notification and badge have it) or the hour's cap is reached:
        # either way the key is handled, never pushed later.
        def send_show(show, open)
          return if @refused

          subs = targets(show.attention.reason)
          return if subs.empty?

          key = show.attention.key
          if @presence&.present?
            Log.info(:web, "push_skipped", reason: "present", kind: show.attention.reason)
            return handled(key)
          end
          return handled(key) if capped?(show.attention.reason)

          @shown << @now.call
          handled(key) if deliver(subs, show_payload(show, open), show)
        end

        # The retry of one device's show: to that device, if it is still
        # there; not counted against the cap again.
        def send_retry(again, open)
          return if @refused

          sub = @store.for_origin(@origin).find { |candidate| candidate.id == again.sub_id }
          return unless sub

          handled(again.show.attention.key) if deliver([sub], show_payload(again.show, open), again.show, final: true)
        end

        # Over CAP shows in the last CAP_WINDOW: one warning per window.
        def capped?(kind)
          at = @now.call
          @shown.shift while @shown.any? && at - @shown.first >= CAP_WINDOW
          return false if @shown.size < CAP

          if @capped_warned_at.nil? || at - @capped_warned_at >= CAP_WINDOW
            @capped_warned_at = at
            Log.warn(:web, "push_capped", cap: CAP, kind: kind,
                                          echo: "[chi web] #{CAP} pushes in the last hour: holding the rest back")
          end
          true
        end

        # In sent.json: a restart's catch-up skips it.
        def handled(key)
          @store.mark_sent(key)
        rescue SystemCallError => e
          Log.warn(:web, "push_sent_unwritten", error: e.class.name)
        end

        def show_payload(show, open)
          payload = { v: 1, kind: "show", tag: show.attention.key, title: show.title, body: show.body,
                      url: show.url, badge: open.size }
          with_open = payload.merge(open: open)
          JSON.generate(with_open).bytesize <= OPEN_LIMIT ? with_open : payload
        end

        # @param show [Show] its reason: the TTL and urgency, the log
        #   line's kind
        # @param final [Boolean] this is the one retry: a failure is final
        # @return [Boolean] whether any device took it
        def deliver(subs, payload, show, final: false)
          reason = show.attention.reason
          waiting = Attention.waiting?(reason)
          subs.map do |sub|
            result = @client.deliver(sub, payload, ttl: waiting ? SHOW_TTL : EVENT_TTL, urgency: waiting ? "high" : "normal")
            if result.retry_after && !final
              retry_later(show, sub, result)
              next false
            end
            record(sub, result, reason)
            result.ok?
          end.any?
        end

        def retry_later(show, sub, result)
          Log.info(:web, "push_retry", device: sub.id, code: result.code, ms: result.ms, kind: show.attention.reason,
                                       after: result.retry_after)
          @retries[[show.attention.key, sub.id]] = Retry.new(show: show, sub_id: sub.id, at: @now.call + result.retry_after)
        end

        # This origin's devices; a done turn only to those whose prefs ask
        # for it (off by default).
        def targets(reason)
          subs = @store.for_origin(@origin)
          reason == "done" ? subs.select(&:done?) : subs
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
