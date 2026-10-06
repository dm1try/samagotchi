# frozen_string_literal: true

require "time"
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
      # already attached stays as it is.
      # @return [String] the source's name
      # @raise [Error]
      def attach(url: nil, name: nil, cmd: nil, why: nil, hint: nil, every_seconds: nil)
        own = location or raise Error, "this session has no id yet"
        source = url ? from_url(url, name: name, why: why) : from_cmd(name: name, cmd: cmd, why: why, hint: hint, every_seconds: every_seconds)
        return source.name if own.source(source.name)

        own.add(source.with(scope: own.scope))
        source.name
      rescue ContextSources::Invalid, ContextProviders::Invalid => e
        raise Error, e.message
      end

      # This session's sources (its own, then its project's).
      # @return [Array<Hash>] {name:, scope:, why:, hint:, fetched_at:, error:, provider:}
      def list
        id = @host.session_id.call
        return [] unless id

        session = Session.load(id, state_dir: state_dir)
        ContextSources.attached(id, project_root: session.project_root, state_dir: state_dir).map do |attached|
          snapshot = attached.snapshot
          { name: attached.name, scope: attached.location.scope, why: attached.source.why,
            hint: snapshot.hint || attached.source.hint, fetched_at: snapshot.fetched_at, error: snapshot.error,
            provider: attached.source.provider }
        end
      end

      private

      def state_dir = @host.state_dir&.call || Session.default_state_dir

      def location
        id = @host.session_id.call
        id && ContextSources.session_location(id, state_dir: state_dir)
      end

      def from_url(url, name:, why:)
        resolved = ContextProviders.resolve(url) or raise Error, "no installed bundle resolves #{url}"
        source(name: name ? ContextSources.check_name!(name) : resolved.name, cmd: resolved.cmd, why: why || resolved.why,
               hint: resolved.hint, every_seconds: resolved.every_seconds, provider: resolved.bundle)
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
