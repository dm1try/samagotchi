# frozen_string_literal: true

require "time"
require_relative "../config"
require_relative "../context_sources"
require_relative "../project_scope"

module Samagotchi
  module Tools
    # Read the session's attached context (ContextSources): without a name
    # the list, with one its header and text, paged by lines when it is
    # longer than max_tool_output_chars. It reads snapshots only (never
    # runs a source's command) and records what was read, so the web can
    # show a change the agent hasn't read.
    class ContextRead
      NAME = "context_read"
      DEFAULT_MAX_CHARS = 10_000
      # Room for the header and the paging line inside the cap.
      HEADER_ROOM = 1_000

      def self.name = NAME

      # @param content [String] the source's name; blank for the list
      # @param offset [Integer, String, nil] the first line (1-based)
      # @param limit [Integer, String, nil] how many lines at most
      # @param peers [Peers, nil] the session (id, cwd, state dir)
      def self.call(content, offset: nil, limit: nil, peers: nil, max_chars: nil, now: Time.now)
        return "Error: this session's id is not known here" unless peers&.session_id

        new(peers, max_chars: max_chars || config_cap, now: now).run(content.to_s.strip, offset: offset, limit: limit)
      rescue ContextSources::Invalid => e
        "Error: #{e.message}"
      end

      def self.config_cap
        value = Config.get("max_tool_output_chars").to_i
        value.positive? ? value : DEFAULT_MAX_CHARS
      end

      def initialize(peers, max_chars:, now:)
        @state_dir = peers.state_dir
        @own = ContextSources.session_location(peers.session_id, state_dir: @state_dir)
        # The Engine's PeerView knows the session's project; a plain Peers
        # (specs, a bare kernel) has only its folder.
        root = peers.respond_to?(:project_root) ? peers.project_root : ProjectScope.root_for(peers.cwd)
        @attached = ContextSources.attached(peers.session_id, project_root: root, state_dir: @state_dir)
        @max_chars = [max_chars.to_i, HEADER_ROOM * 2].max
        @now = now
      end

      def run(name, offset:, limit:)
        return list if name.empty?

        ContextSources.check_name!(name)
        attached = @attached.find { |a| a.name == name }
        return "Error: no attached source #{name}; context_read without a name lists them" unless attached

        read(attached, offset: offset, limit: limit)
      end

      private

      # Muted sources are left out: this session ignores them.
      def list
        shown = @attached.reject { |a| @own.muted?(a.name) }
        return "No attached context in this session." if shown.empty?

        subs = @own.subscriptions
        lines = shown.map do |a|
          snapshot = a.snapshot
          parts = ["- #{a.name}"]
          parts << "why: #{a.source.why}" if a.source.why
          hint = snapshot.hint || a.source.hint
          parts << "hint: #{hint}" if hint
          if snapshot.text?
            parts << "fetched #{age(snapshot.fetched_at)}"
            parts << "changed since you last read it: #{subs[a.name]&.read == snapshot.revision ? "no" : "yes"}"
          else
            parts << "no text yet"
          end
          parts << "last refresh failed: #{snapshot.error}" if snapshot.error
          parts.join("; ")
        end
        "Attached context (#{shown.size}):\n#{lines.join("\n")}"
      end

      def read(attached, offset:, limit:)
        snapshot = attached.snapshot
        header = header_lines(attached, snapshot)
        unless snapshot.text?
          return "#{header.join("\n")}\nNo text yet#{": the last refresh failed" if snapshot.error}."
        end

        lines = snapshot.text.lines
        first = positive(offset) || 1
        return "#{header.join("\n")}\nThe text has #{lines.size} lines; offset #{first} is past its end." if first > lines.size

        page = lines[(first - 1)..] || []
        page = page.first(positive(limit)) if positive(limit)
        page = fit(page)
        last = first + page.size - 1
        @own.update_subscription(attached.name) { |sub| sub.with(read: snapshot.revision) }

        if first > 1 || last < lines.size
          more = last < lines.size ? " Pass offset: #{last + 1} for more." : ""
          header << "Lines #{first}-#{last} of #{lines.size}.#{more}"
        end
        "#{header.join("\n")}\n---\n#{page.join}"
      end

      def header_lines(attached, snapshot)
        source = attached.source
        hint = snapshot.hint || source.hint
        header = ["#{source.name}#{" (#{hint})" if hint}"]
        header << "Why: #{source.why}" if source.why
        header << "Fetched: #{clock(snapshot.fetched_at)} (#{age(snapshot.fetched_at)})" if snapshot.fetched_at
        header << "Summary: #{snapshot.summary}" if snapshot.summary
        header << "Last refresh failed: #{snapshot.error}" if snapshot.error
        header
      end

      # The lines that fit in the cap (at least one, cut when that one is
      # longer than the cap).
      def fit(lines)
        budget = @max_chars - HEADER_ROOM
        taken = []
        used = 0
        lines.each do |line|
          break if used + line.length > budget && taken.any?

          taken << (line.length > budget ? "#{line[0, budget]}…\n" : line)
          used += line.length
        end
        taken
      end

      def positive(value)
        number = Integer(value.to_s, 10, exception: false)
        number&.positive? ? number : nil
      end

      def clock(iso)
        Time.iso8601(iso).localtime.strftime("%Y-%m-%d %H:%M")
      rescue ArgumentError
        iso.to_s
      end

      def age(iso)
        return "never" unless iso

        seconds = (@now - Time.iso8601(iso)).to_i
        if seconds < 60 then "just now"
        elsif seconds < 3600 then "#{seconds / 60}m ago"
        elsif seconds < 86_400 then "#{seconds / 3600}h ago"
        else
          "#{seconds / 86_400}d ago"
        end
      rescue ArgumentError
        "at an unknown time"
      end
    end
  end
end
