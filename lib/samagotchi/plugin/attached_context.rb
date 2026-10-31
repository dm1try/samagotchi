# frozen_string_literal: true

require "time"
require_relative "../context_candidates"
require_relative "../context_sources"
require_relative "../context_providers"
require_relative "../session"

module Samagotchi
  module Plugin
    # ctx.context (docs/plugins.md, Attached context): context a plugin
    # attaches to its session (ContextSources), through an installed
    # bundle's provider (a URL) or as its own command. In-process, like any
    # plugin code: not gated as `chi context add --cmd` through execute is.
    # The session's worker runs and absorbs it (ContextPoller).
    class AttachedContext
      # An attach that couldn't be done; the message says why.
      class Error < StandardError; end

      # @param host [Host] session_id and state_dir
      def initialize(host, bundle:)
        @host = host
        @bundle = bundle
      end

      # Attach a source to this session. +url+: through an installed
      # bundle's provider (+name+ and +why+ replace the provider's); else
      # +name+ and +cmd+ (+hint+, +every_seconds+). A source of that name
      # already attached stays as it is. One the user removed from the
      # session (its name, or its URL) isn't attached again (#declined?)
      # until the user adds it again, or +force+: the user's own explicit
      # choice (a click), which clears the declined marker (by the name,
      # and by the URL).
      # @return [String, nil] the source's name; nil when declined
      # @raise [Error]
      def attach(url: nil, name: nil, cmd: nil, why: nil, hint: nil, every_seconds: nil, force: false)
        own = own_location!
        source = url ? from_url(url, name: name, why: why) : from_cmd(name: name, cmd: cmd, why: why, hint: hint, every_seconds: every_seconds)
        if force
          own.undecline(source.name, hint: url && source.hint)
        elsif own.declined?(source.name) || (url && own.declined_hints.include?(source.hint))
          return nil
        end
        return source.name if own.source(source.name)

        add(own, source)
      rescue ContextSources::Invalid, ContextProviders::Invalid => e
        raise Error, e.message
      end

      # Marks +name+ (or +url+'s source, through its provider) declined in
      # this session, as the user's removal does: #attach skips it until the
      # user adds it again. An attached source stays (chi context rm).
      # @return [String] the name
      # @raise [Error]
      def decline(url: nil, name: nil)
        own = own_location!
        if url
          resolved = ContextProviders.resolve(url) or raise Error, "no installed bundle resolves #{url}"
          name = name ? ContextSources.check_name!(name) : resolved.name
          hint = resolved.hint
        else
          raise Error, "give url: or name:" if name.to_s.empty?

          name = ContextSources.check_name!(name)
        end
        own.decline(name, hint)
        name
      rescue ContextSources::Invalid, ContextProviders::Invalid => e
        raise Error, e.message
      end

      # Whether the user removed +name+ (or +url+) from this session (so
      # #attach skips it).
      def declined?(name = nil, url: nil)
        own = location or return false
        name_declined?(own, name) || (!url.to_s.empty? && own.declined_hints.include?(url))
      end

      # Proposes a source for this session without attaching it: +url+
      # (through an installed bundle's provider; +name+ replaces the
      # provider's) or +name+ and +cmd+. +title+ is what a person (or a
      # judge) reads, +describe+ more of it, +mentions+ the words an owner
      # prompt names it by (ContextCandidates.mention_in). Idempotent by
      # name: a candidate of that name stays as first proposed. Nothing is
      # proposed in a review session, for a source attached already (by its
      # name or URL, at any scope) or for one the user removed from the
      # session (its name, or its URL). A new candidate an owner prompt
      # already in the session mentions is attached at once (its note comes
      # with the next turn).
      # @return [ContextSources::Candidate, nil] nil when nothing was proposed
      # @raise [Error]
      def propose(title:, url: nil, name: nil, cmd: nil, describe: nil, mentions: [])
        own = own_location!
        candidate = new_candidate(url: url, name: name, cmd: cmd, title: title, describe: describe, mentions: mentions)
        return nil if own.declined?(candidate.name) || (url && own.declined_hints.include?(candidate.url))

        session = saved_session
        return nil if session&.review? || attached?(candidate, session)

        recorded = own.add_candidate(candidate)
        late_match(recorded, own) if recorded.equal?(candidate)
        recorded
      rescue ContextSources::Invalid, ContextProviders::Invalid => e
        raise Error, e.message
      end

      # This session's candidates (#propose), by name; none before the
      # session has an id.
      # @return [Array<ContextSources::Candidate>]
      def candidates
        location&.candidates || []
      end

      # Takes back this session's candidate +name+. A source attached from
      # it stays attached (chi context rm removes that).
      # @return [Boolean] whether there was one
      def withdraw(name)
        location&.remove_candidate(name) || false
      rescue ContextSources::Invalid
        false
      end

      # This session's sources (its own, then its project's); none before
      # the session has an id or a saved file.
      # +summary+ is the last text's summary (nil before any text).
      # @return [Array<Hash>] {name:, scope:, why:, hint:, fetched_at:, error:, provider:, summary:}
      def list
        id = @host.session_id.call
        # No id, or no saved file yet (a command before the first turn).
        return [] unless id && Session.exist?(id, state_dir: state_dir)

        session = Session.load(id, state_dir: state_dir)
        ContextSources.attached(id, project_root: session.project_root, state_dir: state_dir).map do |attached|
          snapshot = attached.snapshot
          { name: attached.name, scope: attached.location.scope, why: attached.source.why,
            hint: snapshot.hint || attached.source.hint, fetched_at: snapshot.fetched_at, error: snapshot.error,
            provider: attached.source.provider, summary: snapshot.summary }
        end
      end

      private

      def state_dir = @host.state_dir&.call || Session.default_state_dir

      # Two attaches at once (a double click): the one that lost the race
      # finds the source there and returns its name too.
      def add(own, source)
        own.add(source.with(scope: own.scope))
        source.name
      rescue ContextSources::Invalid
        raise unless own.source(source.name)

        source.name
      end

      # An invalid name isn't declined (and doesn't hide the URL's check).
      def name_declined?(own, name)
        !name.nil? && own.declined?(name)
      rescue ContextSources::Invalid
        false
      end

      def own_location! = location || raise(Error, "this session has no id yet")

      # The session's saved file, nil before it has one.
      def saved_session
        id = @host.session_id.call
        id && Session.exist?(id, state_dir: state_dir) ? Session.load(id, state_dir: state_dir) : nil
      end

      def attached?(candidate, session)
        ContextSources.attached(session&.id || @host.session_id.call, project_root: session&.project_root,
                                                                      state_dir: state_dir, shadowed: true)
                      .any? { |a| a.name == candidate.name || (candidate.url && a.source.hint == candidate.url) }
      end

      # A late proposal: the owner's prompts so far may name it already.
      def late_match(candidate, own)
        messages = @host.messages&.call or return
        ContextCandidates.after_propose(candidate, own: own, messages: messages)
      rescue StandardError => e
        Samagotchi::Log.warn(:context, "candidate_late_match_failed", name: candidate.name, error: e.class.name)
      end

      def location
        id = @host.session_id.call
        id && ContextSources.session_location(id, state_dir: state_dir)
      end

      def from_url(url, name:, why:)
        resolved = ContextProviders.resolve(url) or raise Error, "no installed bundle resolves #{url}"
        source(name: name ? ContextSources.check_name!(name) : resolved.name, cmd: resolved.cmd, why: why || resolved.why,
               hint: resolved.hint, every_seconds: resolved.every_seconds, provider: resolved.bundle)
      end

      def new_candidate(url:, name:, cmd:, title:, describe:, mentions:)
        if url
          resolved = ContextProviders.resolve(url) or raise Error, "no installed bundle resolves #{url}"
          name = name ? ContextSources.check_name!(name) : resolved.name
          cmd = nil
        else
          raise Error, "give url: or cmd: (with name:)" if cmd.to_s.strip.empty?

          name = ContextSources.check_name!(name)
        end
        title = ContextSources.one_line(title, ContextSources::LINE_MAX_CHARS) or raise Error, "give title:"
        ContextSources::Candidate.new(
          name: name, url: url&.to_s, cmd: cmd&.to_s, title: title,
          describe: ContextSources.one_line(describe, ContextSources::DESCRIBE_MAX_CHARS),
          mentions: Array(mentions).filter_map { |word| ContextSources.one_line(word.to_s, ContextSources::LINE_MAX_CHARS) }
                                   .uniq.first(ContextSources::MENTIONS_MAX),
          proposed_by: "plugin:#{@bundle}", at: Time.now.utc.iso8601
        )
      end

      def from_cmd(name:, cmd:, why:, hint:, every_seconds:)
        raise Error, "give url: or cmd: (with name:)" if cmd.to_s.strip.empty?

        source(name: ContextSources.check_name!(name), cmd: cmd.to_s, why: why, hint: hint,
               every_seconds: ContextSources.check_every!(every_seconds), provider: nil)
      end

      def source(name:, cmd:, why:, hint:, every_seconds:, provider:)
        ContextSources::Source.new(
          name: name, cmd: cmd, every_seconds: every_seconds,
          why: ContextSources.one_line(why, ContextSources::LINE_MAX_CHARS),
          hint: ContextSources.one_line(hint, ContextSources::LINE_MAX_CHARS), scope: nil,
          added_by: "plugin:#{@bundle}", created_at: Time.now.utc.iso8601, provider: provider
        )
      end
    end
  end
end
