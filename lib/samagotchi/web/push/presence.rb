# frozen_string_literal: true

module Samagotchi
  module Web
    module Push
      # Whether the owner is at a chi web page now (the plan's D3: no push
      # while they look): each page reports {page, front} (POST
      # /api/push/presence; front = visible, focused and touched in the last
      # 2 min) when that changes and every 30 s while front. The iPhone's
      # service worker can't see the app in front, so this is decided here.
      # In memory only (a restart forgets it: a page reports again within
      # 30 s), shared by the route and the Notifier through Push::Runtime.
      class Presence
        # A front report counts this long: a page that stopped reporting (a
        # closed laptop, a lost network) quiets the phone no longer.
        TTL = 45.0
        # Pages remembered (one per page load): the oldest report goes.
        MAX_PAGES = 64
        PAGE_MAX = 64

        Report = Data.define(:front, :at)

        # @param now [#call] monotonic seconds (specs move it)
        def initialize(now: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @now = now
          @mutex = Mutex.new
          @pages = {} # page id → Report, oldest first
        end

        # A page's report: +page+ its id for this load, +front+ whether the
        # user is at it.
        def report(page, front)
          @mutex.synchronize do
            @pages.delete(page)
            @pages[page] = Report.new(front: front == true, at: @now.call)
            @pages.shift while @pages.size > MAX_PAGES
          end
          nil
        end

        # Some page is in front, reported in the last TTL seconds.
        def present?
          at = @now.call
          @mutex.synchronize { @pages.each_value.any? { |r| r.front && at - r.at < TTL } }
        end

        # A report's body as the page sends it: {page: id, front: bool}.
        # @return [Array(String, Boolean), nil] nil when it isn't one
        def self.parse(body)
          return nil unless body.is_a?(Hash)

          page, front = body.values_at("page", "front")
          return nil unless page.is_a?(String) && !page.empty? && page.bytesize <= PAGE_MAX && [true, false].include?(front)

          [page, front]
        end
      end
    end
  end
end
