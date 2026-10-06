# frozen_string_literal: true

require "uri"

module Samagotchi
  module Broadcast
    # A cheap, deterministic marker found in a note or about a session: a
    # ticket id, a pull request, a link. A tag the note and a session share
    # delivers the note there without asking a model (the fast path).
    # @!attribute kind [String] "ticket", "pr" or "link"
    # @!attribute value [String] "PAY-123"; "#42" or "acme/shop#42"; a
    #   link's host and path ("notion.so/team/checkout-v2")
    # @!attribute from [String] where it was found: "note", "branch",
    #   "messages" (the user's prompts) or "context <name>" (an attached
    #   context source)
    Tag = Data.define(:kind, :value, :from) do
      def label = "#{kind} #{value}"

      # Same kind and value; a pr with no repo matches the same number in
      # any repo.
      def matches?(other)
        return false unless kind == other.kind
        return value == other.value unless kind == "pr"

        number, repo = Tags.pr_parts(value)
        other_number, other_repo = Tags.pr_parts(other.value)
        number == other_number && (repo.nil? || other_repo.nil? || repo == other_repo)
      end
    end

    # A tag of the note and the session tag it matched.
    Match = Data.define(:note_tag, :session_tag) do
      # For the broadcast's output: "ticket PAY-123 matches (branch)".
      def reason = "#{note_tag.label} matches (#{session_tag.from})"

      # For the note the session gets: "ticket PAY-123 matches your branch".
      def because
        tag = session_tag
        case tag.from
        when "branch" then "#{note_tag.label} matches your branch"
        when "messages" then "#{note_tag.label} is in your user's messages too"
        else "#{note_tag.label} matches your attached #{tag.from}"
        end
      end
    end

    # Tags from text, a branch and attached context, and the first match
    # between a note's and a session's.
    module Tags
      DEFAULT_TICKET_PATTERN = '\b[A-Z][A-Z0-9]+-\d+\b'
      # Words the default ticket pattern would take that are no ticket.
      NOT_TICKETS = %w[UTF SHA ISO IEC RFC GPT AES RSA ECMA ES HTTP TLS SSL MD IPV X].freeze
      URL_RE = %r{https?://[^\s<>()\[\]{}"'`|]+}
      PR_URL_RE = %r{\A(?:www\.)?github\.com/([^/]+/[^/]+)/pull/(\d+)}i
      PR_TEXT_RE = /\bPR\s?#(\d+)\b/i
      PR_SOURCE_RE = /\Apr-(\d+)\z/
      # The order matches are looked for in: the most specific first.
      KINDS = %w[ticket pr link].freeze

      module_function

      # broadcast.ticket_pattern as a Regexp; nil, empty or invalid → the
      # default (an invalid one is reported through +warn+).
      # @return [Regexp]
      def ticket_regexp(pattern, warn: nil)
        return Regexp.new(DEFAULT_TICKET_PATTERN) if pattern.to_s.strip.empty?

        Regexp.new(pattern.to_s)
      rescue RegexpError => e
        warn&.call("broadcast.ticket_pattern #{pattern.inspect} is not a valid pattern (#{e.message}); using the default")
        Regexp.new(DEFAULT_TICKET_PATTERN)
      end

      # @return [Array<Tag>] the tags in +text+ (a note, the user's prompts)
      def of_text(text, from:, ticket: ticket_regexp(nil))
        text = text.to_s
        found = tickets(text, ticket, from: from)
        found += text.scan(PR_TEXT_RE).map { |(number)| Tag.new(kind: "pr", value: "##{number}", from: from) }
        text.scan(URL_RE).each { |url| found += of_url(url, from: from) }
        found.uniq
      end

      # A session's tags: its branch (matched whatever its case: branches
      # are often lowercase), the user's messages, its attached context
      # (a pr-<n> source and every source's URL hint).
      # @param sources [Array<Array(String, String)>] [name, hint] pairs
      # @return [Array<Tag>]
      def of_session(branch:, messages:, sources:, ticket: ticket_regexp(nil))
        found = tickets(branch.to_s, Regexp.new(ticket.source, ticket.options | Regexp::IGNORECASE), from: "branch")
        found += messages.flat_map { |text| of_text(text, from: "messages", ticket: ticket) }
        sources.each do |name, hint|
          from = "context #{name}"
          from_hint = hint.to_s.scan(URL_RE).flat_map { |url| of_url(url, from: from) }
          number = name.to_s[PR_SOURCE_RE, 1]
          # pr-<n> with no PR URL in its hint: the number alone, any repo
          found << Tag.new(kind: "pr", value: "##{number}", from: from) if number && from_hint.none? { |t| t.kind == "pr" }
          found += from_hint
        end
        found.uniq { |tag| [tag.kind, tag.value] }
      end

      # The first session tag a note tag matches, tickets first, then pull
      # requests, then links.
      # @return [Match, nil]
      def match(note_tags, session_tags)
        KINDS.each do |kind|
          note_tags.each do |tag|
            next unless tag.kind == kind

            hit = session_tags.find { |other| tag.matches?(other) }
            return Match.new(note_tag: tag, session_tag: hit) if hit
          end
        end
        nil
      end

      # "acme/shop#42" → ["42", "acme/shop"]; "#42" → ["42", nil].
      def pr_parts(value)
        repo, number = value.to_s.split("#", 2)
        [number, repo.to_s.empty? ? nil : repo.downcase]
      end

      def tickets(text, regexp, from:)
        text.to_enum(:scan, regexp).filter_map do
          id = Regexp.last_match(0).upcase
          next if NOT_TICKETS.include?(id.split("-", 2).first)

          Tag.new(kind: "ticket", value: id, from: from)
        end
      end
      private_class_method :tickets

      # A link's host and path, without the scheme, www., the query, the
      # fragment or a trailing slash; a pull request URL is a pr tag too. A
      # bare host ("https://github.com/") says too little to be a tag.
      def of_url(url, from:)
        uri = URI.parse(url.sub(/[.,;:!?]+\z/, ""))
        host = uri.host.to_s.downcase.delete_prefix("www.")
        path = uri.path.to_s.chomp("/")
        return [] if host.empty? || path.empty?

        link = "#{host}#{path}"
        tags = [Tag.new(kind: "link", value: link, from: from)]
        if (pr = link.match(PR_URL_RE))
          tags.unshift(Tag.new(kind: "pr", value: "#{pr[1].downcase}##{pr[2]}", from: from))
        end
        tags
      rescue URI::Error
        []
      end
      private_class_method :of_url
    end
  end
end
