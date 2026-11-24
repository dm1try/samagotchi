# frozen_string_literal: true

require "time"
require_relative "../pages"
require_relative "../pages/launch"

module Samagotchi
  module Web
    # The pages routes, mixed into App (docs/internals/pages.md, chi web): the
    # list for the Pages list and the pages pill, a page as stored (opening runs
    # nothing), Refresh (one run through Pages::Launch, inside the request)
    # and Delete. All the owner's: a participant never sees pages. The name
    # is checked (Pages.valid_name?) before anything builds a path; one that
    # breaks the rule is no such page.
    module PageRoutes
      ROUTES = [
        ["GET", %r{\A/api/pages\z}, :handle_pages_list, :owner],
        ["GET", %r{\A/api/pages/([^/]+)\z}, :handle_page_show, :owner],
        ["POST", %r{\A/api/pages/([^/]+)/run\z}, :handle_page_run, :owner],
        ["DELETE", %r{\A/api/pages/([^/]+)\z}, :handle_page_delete, :owner]
      ].freeze

      # How much of a failed run's stderr the answer carries (its tail).
      STDERR_BYTES = 2048

      private

      # GET /api/pages: {pages: [{name, title, state, ran_at, failed_at,
      # changed, error_line, bundle}]}, by name (+bundle+: the bundle whose
      # page it is, Pages::Bundled; nil for the owner's own).
      def handle_pages_list(_req)
        rows = Pages::Store.list.map do |page|
          { name: page.name, title: page.title, state: page.state.to_s, ran_at: page.ran_at, failed_at: page.error&.at,
            changed: page.changed?, error_line: page.error&.line, bundle: page.bundle }
        end
        json_response(200, { pages: rows })
      end

      # GET /api/pages/NAME: the page as stored (#page_json); 404 page_missing.
      def handle_page_show(_req, name)
        return page_missing(name) unless Pages.valid_name?(name) && File.file?(Pages.script_path(name))

        json_response(200, page_json(Pages::Store.read(name)))
      end

      # POST /api/pages/NAME/run: the page as after the run, with +stderr+
      # (its last STDERR_BYTES) when it failed. 409 page_busy, 404
      # page_missing, 503 server_stopping (chi web's stop ends the run:
      # Launch's cancelled:, "the run was stopped").
      def handle_page_run(_req, name)
        return page_missing(name) unless Pages.valid_name?(name)

        running = @server_running
        result = Pages::Launch.run(name, timeout: Pages::TIMEOUT_SECONDS, cancelled: -> { !running.call })
        return error_response(503, "server_stopping", "chi web is stopping; Refresh again") unless running.call

        json = page_json(result.page)
        json[:stderr] = tail(result.stderr) unless result.ok?
        json_response(200, json)
      rescue Pages::Missing => e
        error_response(404, "page_missing", e.message)
      rescue Pages::Busy => e
        error_response(409, "page_busy", e.message)
      end

      # DELETE /api/pages/NAME: the script and its result. {removed: NAME};
      # 409 page_busy, 409 page_bundled (a bundle's page: Pages::FromBundle),
      # 404 page_missing.
      def handle_page_delete(_req, name)
        return page_missing(name) unless Pages.valid_name?(name)

        Pages::Store.remove(name)
        json_response(200, { removed: name })
      rescue Pages::Missing => e
        error_response(404, "page_missing", e.message)
      rescue Pages::Busy => e
        error_response(409, "page_busy", e.message)
      rescue Pages::FromBundle => e
        error_response(409, "page_bundled", e.message)
      end

      def page_missing(name) = error_response(404, "page_missing", Pages::Missing.new(name).message)

      # A page for the view. +changed+: the result came from an older script
      # (Stored#changed?); +changed_after_failure+: the script differs from
      # the one that failed, so the view needs no sha. +script_changed_at+:
      # the script file's mtime. +bundle+: the bundle whose page it is (the
      # view offers no Delete), nil for the owner's own. A text block carries
      # +html+ (sanitised) when Markdown rendering is available.
      def page_json(page)
        error = page.error
        { name: page.name, title: page.title, state: page.state.to_s, ran_at: page.ran_at, duration_ms: page.duration_ms,
          changed: page.changed?, bundle: page.bundle,
          changed_after_failure: !error.nil? && !error.script_sha.nil? && !page.current_sha.nil? &&
            error.script_sha != page.current_sha,
          script_changed_at: script_mtime(page.name),
          error: error && { message: error.message, line: error.line, at: error.at },
          blocks: page.blocks.map { |block| with_html(block) } }
      end

      def with_html(block)
        return block unless block.is_a?(Hash) && block["type"] == "text" && block["text"].is_a?(String)
        return block unless @markdown_renderer.available?

        block.merge("html" => @markdown_renderer.render(block["text"]))
      end

      def script_mtime(name)
        File.mtime(Pages.script_path(name)).utc.iso8601
      rescue SystemCallError
        nil
      end

      def tail(text)
        return text if text.bytesize <= STDERR_BYTES

        text.byteslice(-STDERR_BYTES, STDERR_BYTES).scrub("")
      end
    end
  end
end
