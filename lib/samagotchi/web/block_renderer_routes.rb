# frozen_string_literal: true

require_relative "../block_renderers"

module Samagotchi
  module Web
    # What the owner's page asks to draw a fenced block (App::ROUTES, :owner
    # rows; a participant's page shows the source). Included in App: its helpers
    # answer. docs/internals/block-renderers.md.
    module BlockRendererRoutes
      private

      # {renderers: [{lang, bundle, files}]}
      def handle_block_renderers(_req)
        json_response(200, { renderers: BlockRenderers.for_installed.map(&:to_h) })
      end

      # One of a renderer's files. The captures are the URL's and unchecked:
      # BlockRenderers.script_path never makes a path of one that isn't a
      # renderer's. A file changed since the install gets an error, so the page
      # keeps the block as source.
      def handle_block_renderer_file(req, bundle, file)
        path = BlockRenderers.script_path(bundle, file)
        return not_found(path: req.path_info) unless path

        revalidated_body(req, File.binread(path), "text/javascript; charset=utf-8")
      rescue BlockRenderers::Invalid => e
        error_response(409, "renderer_changed", e.message)
      end
    end
  end
end
