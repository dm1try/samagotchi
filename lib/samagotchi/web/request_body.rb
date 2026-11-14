# frozen_string_literal: true

module Samagotchi
  module Web
    # Every request body chi web reads, read through #request_body: capped,
    # 64 KB unless the call names its own cap (an image's 20 MB, an owner's
    # turn 16 MB, …). Over the cap is BodyTooLarge, which App#route answers
    # 413 too_large with Connection: close (Web::Server then doesn't drain
    # the rest). Rack's req.params / req.POST would read a form body
    # uncapped: chi web reads a query with req.GET
    # (spec/web/no_body_params_spec.rb). Included in App.
    # See docs/internals/participants.md (The gate).
    module RequestBody
      SMALL_BODY_LIMIT = 64 * 1024
      # An owner's turn or new session: prompt text and small fields (images
      # are refs to separate uploads). A big piped `chi send` is a big
      # prompt; over this it goes the Bridge's 413 way, into the input-file
      # fallback (SessionManager::Delivery). It stays at most
      # 32 × Bridge::MAX_BODY_BYTES, what the Bridge skips before its 413.
      OWNER_TURN_BODY_LIMIT = 16 * 1024 * 1024
      # What the worker's Bridge takes (Bridge::MAX_BODY_BYTES's number: chi
      # web doesn't load the Bridge; spec/web/request_body_cap_spec.rb keeps
      # them equal): a participant's turn and an answer, which chi web
      # relays to it.
      BRIDGE_BODY_LIMIT = 1_000_000
      # POST …/context/:name/push: a text up to ContextSources::TEXT_MAX_BYTES
      # (1 MB), JSON-escaped (a control character is 6 bytes).
      CONTEXT_PUSH_BODY_LIMIT = 16 * 1024 * 1024

      # A body over its cap. The message is the 413's one text: "<what> may
      # be up to <size>".
      class BodyTooLarge < StandardError
        attr_reader :limit, :what

        def initialize(limit, what)
          @limit = limit
          @what = what
          super("#{what} may be up to #{RequestBody.size_words(limit)}")
        end
      end

      # 65_536 → "64 KB", 20_971_520 → "20 MB", 1_000_000 (the Bridge's
      # cap) → "1 MB", 1000 → "1000 bytes".
      def self.size_words(bytes)
        mib = 1024 * 1024
        return "#{bytes / mib} MB" if bytes >= mib && (bytes % mib).zero?
        return "#{bytes / 1_000_000} MB" if bytes >= 1_000_000 && (bytes % 1_000_000).zero?
        return "#{bytes / 1024} KB" if bytes >= 1024 && (bytes % 1024).zero?

        "#{bytes} bytes"
      end

      private

      # The request body, "" when there is none: WEBrick (through rackup)
      # raises LengthRequired on reading a POST that has neither a
      # Content-Length nor a chunked body (plain `curl -X POST`). Over
      # +limit+ bytes, by its Content-Length (nothing read) or by what came
      # (a chunked body, a Content-Length that lies: at most limit + 1
      # read), it raises BodyTooLarge naming +what+.
      def request_body(req, limit = SMALL_BODY_LIMIT, what: "a request body")
        return "" if req.get_header("CONTENT_LENGTH").nil? && req.get_header("HTTP_TRANSFER_ENCODING").nil?
        raise BodyTooLarge.new(limit, what) if req.content_length.to_i > limit

        raw = req.body.read(limit + 1).to_s
        raise BodyTooLarge.new(limit, what) if raw.bytesize > limit

        raw
      end
    end
  end
end
