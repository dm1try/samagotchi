# frozen_string_literal: true

require_relative "log"

module Samagotchi
  # A logged degradation: a piece of work whose failure has a fallback (a
  # prompt section left out, an empty list, nil), with a record in the debug
  # log instead of silence.
  #
  #   Degrade.call(:prompt, "model_notes_unreadable", fallback: nil, model: name) { read_notes }
  #   Degrade.call(:bridge, "state_unreadable", fallback: {}, rescue: [SystemCallError, JSON::ParserError]) { … }
  #
  # Runs the block and returns its value. When it raises one of +rescue:+
  # (StandardError by default; never Exception), returns +fallback+ and logs
  # Log.warn(area, event, error:, msg:, **fields) the first time this
  # process sees [area, event], Log.debug after: a hot path that fails on
  # every call writes one WARN, and the happy path takes no lock. Nothing
  # goes to stderr (a worker has none; a terminal line would be noise).
  #
  # A `return` in the block returns from the enclosing method as usual; a
  # `next` or `break` would change what the site does, so a site that needs
  # one logs by hand (Degrade.note) instead.
  #
  # Written Degrade.call (Style/LambdaCall turns Degrade.() into it).
  #
  # +area+ is a Log tag (LogLine::TAGS), +event+ a slug saying what was
  # lost; with Log's strict mode on (the specs) both are checked on every
  # call, the happy path's included.
  module Degrade
    MSG_CHARS = 500

    @seen = Set.new
    @mutex = Mutex.new

    class << self
      # @param area [Symbol] a Log tag
      # @param event [String, Symbol] what was lost (agents_md_unreadable)
      # @param fallback [Object] the value when the block raises
      # @param fields [Hash] extra record fields; +rescue:+ (a class or an
      #   array of them, default StandardError) is the one taken out
      # @return the block's value, or +fallback+
      def call(area, event, fallback: nil, **fields)
        classes = Array(fields.delete(:rescue) || StandardError)
        check!(area, event) if Log.strict
        begin
          yield
        rescue *classes => e
          note(area, event, e, **fields)
          fallback
        end
      end

      # Log a degradation the caller has already handled (its rescue keeps
      # a next/break or a fallback of its own): the same once-per-process
      # WARN, DEBUG after.
      # @return nil
      def note(area, event, error, **fields)
        first = @mutex.synchronize { @seen.add?([area.to_sym, event.to_s]) }
        record = { error: error.class.name, msg: error.message.to_s[0, MSG_CHARS], **fields }
        first ? Log.warn(area, event.to_s, **record) : Log.debug(area, event.to_s, **record)
        nil
      end

      # Forget what was logged (specs, with Log.reset!).
      def reset! = @mutex.synchronize { @seen.clear }

      private

      def check!(area, event)
        raise ArgumentError, "unknown log tag #{area}" unless LogLine::TAGS.include?(area.to_s)
        raise ArgumentError, "bad log event #{event}" unless event.to_s.match?(LogLine::SLUG)
      end
    end
  end
end
