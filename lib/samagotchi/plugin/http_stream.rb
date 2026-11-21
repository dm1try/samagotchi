# frozen_string_literal: true

require "json"
require_relative "http_errors"
require_relative "sse_reader"

module Samagotchi
  module Plugin
    class Http
      # The answer ctx.http.stream's block gets (docs/plugins.md, "Calling
      # services"): the status and headers before any of the body, then the
      # body, read once, by one of #each_event, #each_chunk or #body. After
      # one of them has read it, another read gives nothing (#body is "").
      #
      # A read that fails on the wire raises the HttpError (or
      # HttpCancelled) the transport maps it to, from inside the read: the
      # plugin's block never sees a raw IOError or Net::ReadTimeout. An
      # error the plugin's own block raises while reading goes on as it is.
      class Stream
        attr_reader :status, :headers

        # @param status [Integer]
        # @param headers [Hash] frozen, lower-case names
        # @param reader [#call] call { |bytes| … } reads the rest of the body
        # @param failure [#call] (raw error) → the error to raise instead
        def initialize(status:, headers:, reader:, failure: ->(error) { error })
          @status = status
          @headers = headers
          @reader = reader
          @failure = failure
          @read = false
        end

        # @return [Boolean] a 2xx status
        def ok? = status.between?(200, 299)

        # @yield [String] each piece of the body as it arrives (binary)
        # @return [nil]
        def each_chunk(&block)
          raise ArgumentError, "each_chunk needs a block" unless block
          return nil if @read

          @read = true
          inside = false
          @reader.call do |bytes|
            inside = true
            yield(bytes)
            inside = false
          end
          nil
        rescue StandardError => e
          raise if inside

          raise @failure.call(e)
        end

        # The body as Server-Sent Events (SseReader's rules).
        # @yield [SseReader::Event]
        # @return [nil]
        def each_event(&block)
          raise ArgumentError, "each_event needs a block" unless block

          reader = SseReader.new
          each_chunk { |bytes| reader.feed(bytes, &block) }
        end

        # @return [String] the rest of the body, read to its end: UTF-8 when
        #   its bytes are, else binary; "" once the body was read
        def body
          bytes = +"".b
          each_chunk { |chunk| bytes << chunk }
          Http.text(bytes)
        end

        # #body parsed as JSON.
        # @raise [HttpError] the body isn't JSON
        def json
          text = body
          JSON.parse(text)
        rescue JSON::ParserError, EncodingError
          raise HttpError, "not JSON: status #{status}, #{text.to_s.bytesize} bytes"
        end
      end
    end
  end
end
