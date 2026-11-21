# frozen_string_literal: true

module Samagotchi
  module Plugin
    # ctx.http failed: the request didn't complete (refused, timed out, DNS,
    # TLS, reset, a malformed response, a bad gzip body), or Response#json
    # was called on a body that isn't JSON. The message says what and where,
    # never headers or a body; the original error is the #cause.
    class HttpError < StandardError; end

    # A ctx.http request was cancelled (its cancel: controller, or the turn's
    # Stop).
    class HttpCancelled < HttpError; end
  end
end
