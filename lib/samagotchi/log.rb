# frozen_string_literal: true

require "monitor"
require_relative "log_line"
require_relative "debug_log"

module Samagotchi
  autoload :Config, File.expand_path("config", __dir__)
  autoload :LogPath, File.expand_path("log_path", __dir__)

  # The one logging facade: tagged, levelled records in the debug log
  # (LogPath, format in LogLine), one process-wide sink.
  #
  #   Log.info(:worker, "idle_exit", idle_s: 1800)
  #   Log.warn(:hooks, "hook_failed", echo: "[samagotchi:hooks] …")
  #   Log.debug(:model, "response", payload: text, model: "qwen")
  #
  # echo: is for what used to be a plain `warn`: that text still goes to
  # stderr unchanged (whatever the level; not in a worker, see configure)
  # and becomes the record's msg= field.
  #
  # Unconfigured, the first record resolves the file and level from Config
  # (once, until Config.reload!). While that runs (Config can warn itself)
  # records only echo. Nothing here raises into the caller: a record that
  # can't be formatted is dropped, an unwritable file pauses (DebugLog).
  module Log
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }.freeze
    DEFAULT_LEVEL = :info
    MAX_PAYLOAD_BYTES = 64 * 1024
    SID_LENGTH = 8
    BACKTRACE_FRAMES = 20
    # A field named like a credential never shows its value. Whole name
    # segments, so counts like prompt_tokens stay readable.
    SECRET_KEY = /(?:\A|_)(?:key|api_?key|token|secret|authorization|auth|password|passwd|cookie)(?:\z|_)/
    URL = %r{\A[a-z][a-z0-9+.-]*://}i

    @monitor = Monitor.new
    @options = {}
    @state = nil
    @resolving = false
    @session_id = nil

    class << self
      # @param path [String, nil, :auto] the file; :auto → LogPath.resolve
      # @param level [Symbol, String, nil] nil → log.level
      # @param stderr [Boolean] false in a worker: echo: text goes nowhere
      #   (its stderr is /dev/null anyway), only to the file
      # @param mirror [Boolean] -v: every record written also goes to stderr
      def configure(path: :auto, level: nil, stderr: true, mirror: false)
        @monitor.synchronize do
          close_state
          @options = { path: path, level: level, stderr: stderr, mirror: mirror }
        end
        self
      end

      # Back to unconfigured (specs: before each example).
      def reset!
        @monitor.synchronize do
          close_state
          @options = {}
          @session_id = nil
        end
      end

      # Config changed (Config.reload!): resolve :auto parts again.
      def invalidate!
        @monitor.synchronize { close_state }
      end

      # The session this process works for (a worker, the REPL); records
      # carry its first SID_LENGTH chars unless they pass their own sid:.
      attr_accessor :session_id

      def debug(tag, event, **kw) = log(:debug, tag, event, **kw)
      def info(tag, event, **kw) = log(:info, tag, event, **kw)
      def warn(tag, event, **kw) = log(:warn, tag, event, **kw)
      def error(tag, event, **kw) = log(:error, tag, event, **kw)

      # ERROR with the exception and its first BACKTRACE_FRAMES frames as
      # the payload (crashes of threads and workers).
      def exception(tag, event, error, echo: nil, **fields)
        frames = Array(error.backtrace).first(BACKTRACE_FRAMES)
        log(:error, tag, event, echo: echo, payload: frames.join("\n"),
                                error: error.class.name, msg: error.message.to_s[0, 500], **fields)
      end

      # Whether a record at this level reaches the file or stderr (to skip
      # building a big payload for nothing).
      def level?(level)
        state = resolved_state
        state ? LEVELS.fetch(level.to_sym) >= state[:level] : false
      end

      def path
        resolved_state&.dig(:writer)&.path
      end

      def log(level, tag, event, payload: nil, sid: nil, echo: nil, **fields)
        options = @options
        echo_to_stderr(echo) if echo && options.fetch(:stderr, true)
        state = resolved_state
        return nil unless state && LEVELS.fetch(level) >= state[:level]

        fields = { msg: echo }.merge(fields) if echo && !fields.key?(:msg)
        text = build(level, tag, event, payload: payload, sid: sid || @session_id, fields: fields)
        return nil unless text

        state[:writer].write(text)
        mirror(text) if state[:mirror] && !echo
        text
      rescue StandardError
        nil
      end

      private

      def build(level, tag, event, payload:, sid:, fields:)
        tag = tag.to_s
        event = event.to_s
        raise ArgumentError, "unknown log tag #{tag}" unless LogLine::TAGS.include?(tag)
        raise ArgumentError, "bad log event #{event}" unless event.match?(LogLine::SLUG)

        fields = fields.each_with_object({}) do |(key, value), out|
          key = key.to_s
          next if value.nil? || !key.match?(LogLine::KEY)

          out[key] = safe_value(key, value)
        end
        payload = payload.to_s if payload
        if payload && payload.bytesize > MAX_PAYLOAD_BYTES
          fields["truncated"] = payload.bytesize - MAX_PAYLOAD_BYTES
          payload = payload.byteslice(0, MAX_PAYLOAD_BYTES)
        end
        LogLine.format(LogLine::Record.new(
          ts: Time.now, level: level.to_s.upcase, tag: tag, pid: Process.pid,
          sid: sid && sid.to_s[0, SID_LENGTH], event: event, fields: fields, payload: payload
        ))
      rescue StandardError
        nil
      end

      def safe_value(key, value)
        return "[redacted]" if key.match?(SECRET_KEY)

        value = value.is_a?(Float) ? value.round(3) : value
        value.is_a?(String) && value.match?(URL) ? safe_url(value) : value
      end

      # No userinfo, no query or fragment (keys ride there sometimes).
      def safe_url(url)
        url.sub(%r{\A([a-z][a-z0-9+.-]*://)[^/?#@]*@}i, "\\1").sub(/[?#].*\z/m, "")
      end

      def echo_to_stderr(text)
        $stderr.puts(text)
      rescue StandardError
        nil
      end

      def mirror(text)
        $stderr.write(text)
      rescue StandardError
        nil
      end

      def resolved_state
        state = @state
        return state if state

        @monitor.synchronize do
          return @state if @state
          # Config.get below may log a warning: that one only echoes.
          return nil if @resolving

          @resolving = true
          begin
            @state = build_state
          ensure
            @resolving = false
          end
        end
      end

      def build_state
        options = @options
        path = options.fetch(:path, :auto)
        path = (LogPath.resolve rescue nil) if path == :auto
        level = options[:level] || (Config.get("log.level") rescue nil)
        level = LEVELS.key?(level.to_s.downcase.to_sym) ? level.to_s.downcase.to_sym : DEFAULT_LEVEL
        { writer: DebugLog.new(path: path), level: LEVELS.fetch(level), mirror: options[:mirror] ? true : false }
      end

      def close_state
        @state&.dig(:writer)&.close
        @state = nil
      end
    end
  end
end
