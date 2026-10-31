# frozen_string_literal: true

require "time"
require_relative "context_absorber"
require_relative "context_candidates_log"
require_relative "context_fetch"
require_relative "context_providers"
require_relative "context_sources"
require_relative "log"
require_relative "owner_prompt"

module Samagotchi
  # A session's pool of candidate context (ContextSources::Candidate, from
  # ctx.context.propose) and the one thing that attaches one in slice 1:
  # the owner mentioning it. A candidate's status is derived, never stored:
  # attached while a source of its name (or its URL) is attached, declined
  # while the user's declined marker names it (or its URL), else proposed.
  #
  # Mentions (#mention_in): whole tokens, any case; a "#N" only for N ≥ 10
  # or right after "PR" / "pull" ("PR #4"); any other word (a branch) only
  # when it is at least 6 characters and holds a /, - or _; a URL exactly.
  # Text inside fenced code blocks (pasted logs) never counts.
  #
  # Only the owner's own prompts count (OwnerPrompt), and nothing happens in
  # a review session: a participant never attaches a source to the owner's
  # session.
  module ContextCandidates
    STATUSES = %w[proposed attached declined].freeze
    # How long a turn waits for a mention-attached source's first text, so
    # its note lands in the turn that mentioned it; past it the note comes
    # with a later turn.
    FIRST_FETCH_SECONDS = 10
    BRANCH_MIN_CHARS = 6
    NUMBER_MIN = 10
    # A fenced code block's opening line (up to 3 spaces, then ``` or ~~~).
    FENCE_OPEN = /\A {0,3}(`{3,}|~{3,})/
    # What may sit around a word-like mention without joining it.
    WORD_BEFORE = %r{(?<![\w./#-])}
    WORD_AFTER = %r{(?![\w/-])(?!\.[\w/-])}
    # A candidate attached from a mention, and the mention.
    Hit = Data.define(:candidate, :mention)

    module_function

    # @param attached [Array<ContextSources::Attached>] what the session sees
    # @return [String] "attached", "declined" or "proposed"
    def status(candidate, own:, attached:)
      if attached.any? { |a| a.name == candidate.name || (candidate.url && a.source.hint == candidate.url) }
        return "attached"
      end
      return "declined" if own.declined?(candidate.name) || (candidate.url && own.declined_hints.include?(candidate.url))

      "proposed"
    end

    # The session's candidates with their status, by name.
    # @return [Array<Array(ContextSources::Candidate, String)>]
    def with_status(session_id, project_root:, state_dir: nil)
      own = ContextSources.session_location(session_id, state_dir: state_dir)
      candidates = own.candidates
      return [] if candidates.empty?

      attached = ContextSources.attached(session_id, project_root: project_root, state_dir: state_dir, shadowed: true)
      candidates.map { |candidate| [candidate, status(candidate, own: own, attached: attached)] }
    end

    # The candidates section of /context, nil for none.
    def listing(session_id, project_root:, state_dir: nil)
      rows = with_status(session_id, project_root: project_root, state_dir: state_dir)
      return nil if rows.empty?

      lines = rows.map { |candidate, state| "- #{candidate.name} · #{state} · #{candidate.title}" }
      "Candidates (attached when a prompt of yours mentions one, or by /context attach NAME):\n#{lines.join("\n")}"
    end

    # The words in +text+ that name +candidate+: its first mention found,
    # or nil.
    def mention_in(text, candidate)
      plain = without_fences(text.to_s)
      return nil if plain.strip.empty?

      candidate.mentions.find { |mention| (pattern = pattern_for(mention)) && plain.match?(pattern) }
    end

    # The regexp a mention matches by, nil for one that never matches (a
    # short or plain word).
    def pattern_for(mention)
      mention = mention.to_s.strip
      if (number = mention[/\A#(\d+)\z/, 1])
        return /(?<![\w&#])##{number}(?!\w)/ if number.to_i >= NUMBER_MIN

        return /\b(?:pr|pull(?:\s+request)?)\s*##{number}(?!\w)/i
      end
      return %r{(?<![\w/.:-])#{Regexp.escape(mention)}(?![\w/#?=&%-])} if mention.match?(%r{\Ahttps?://}i)
      return nil if mention.length < BRANCH_MIN_CHARS || !mention.match?(%r{[/_-]})

      /#{WORD_BEFORE}#{Regexp.escape(mention)}#{WORD_AFTER}/i
    end

    # +text+ with its fenced code blocks blanked out.
    def without_fences(text)
      out = +""
      open = nil
      text.each_line do |line|
        marker = line[FENCE_OPEN, 1]
        if open.nil? && marker
          open = marker
        elsif open && marker && marker[0] == open[0] && marker.length >= open.length && line.strip == marker
          open = nil
        elsif open.nil?
          out << line
        end
      end
      out
    end

    # The owner's own prompts in +messages+ (OwnerPrompt.message?), as text.
    def owner_texts(messages)
      Array(messages).filter_map do |message|
        next unless OwnerPrompt.message?(message)

        content = message.is_a?(Hash) ? (message[:content] || message["content"]) : nil
        content.is_a?(String) ? content : nil
      end
    end

    # The proposed candidates +texts+ mention (the first text that does,
    # newest first), one hit each.
    # @return [Array<Hit>]
    def hits(texts, candidates)
      candidates.filter_map do |candidate|
        mention = texts.reverse_each.lazy.filter_map { |text| mention_in(text, candidate) }.first
        mention && Hit.new(candidate: candidate, mention: mention)
      end
    end

    # Attaches +hit+'s candidate to the session's own folder, its why naming
    # the mention (a mentioned line in ContextCandidatesLog, in +state_dir+'s
    # log). A source of its name there already stays.
    # @return [String, nil] the name, nil when it couldn't be attached
    def attach(hit, own:, state_dir: nil)
      candidate = hit.candidate
      own.add(source_for(candidate, why: "you mentioned #{hit.mention}"))
      Log.info(:context, "candidate_attached", name: candidate.name, trigger: "mention")
      ContextCandidatesLog.event("mentioned", session_id: own.key, name: candidate.name, state_dir: state_dir,
                                              mention: hit.mention)
      candidate.name
    rescue ContextSources::Invalid, ContextProviders::Invalid => e
      return candidate.name if own.source(candidate.name)

      Log.warn(:context, "candidate_not_attached", name: candidate.name, error: e.message.to_s[0, 200])
      nil
    end

    # The Source a candidate becomes: through its URL's provider, else its
    # own command.
    # @raise [ContextProviders::Invalid] no installed bundle resolves its URL
    def source_for(candidate, why:)
      fields = { name: candidate.name, why: why, scope: "session", added_by: candidate.proposed_by,
                 created_at: Time.now.utc.iso8601, title: candidate.title }
      if candidate.url
        resolved = ContextProviders.resolve(candidate.url) or
          raise ContextProviders::Invalid, "no installed bundle resolves #{candidate.url}"
        return ContextSources::Source.new(cmd: resolved.cmd, hint: resolved.hint, every_seconds: resolved.every_seconds,
                                          provider: resolved.bundle, **fields)
      end
      ContextSources::Source.new(cmd: candidate.cmd, hint: nil, every_seconds: nil, provider: nil, **fields)
    end

    # The proposed candidates (no source of theirs attached, not declined).
    def proposed(session_id, project_root:, state_dir: nil)
      with_status(session_id, project_root: project_root, state_dir: state_dir)
        .filter_map { |candidate, state| candidate if state == "proposed" }
    end

    # Turn start (Worker#run_prompt before its absorb; the REPL's turn):
    # the proposed candidates +prompt+ (or an earlier owner prompt: a late
    # proposal) mentions are attached, then each gets one first fetch
    # (together within +seconds+), so the note reaches this turn. Only an
    # owner's turn (OwnerPrompt.turn?). Also fetches a candidate attached
    # since the last turn whose source has never been tried.
    # @param session [Session]
    # @param cancelled [#call] true: stop waiting (the session was stopped)
    # @return [Array<String>] the names attached now
    def before_turn(session:, prompt:, author:, state_dir: nil, seconds: FIRST_FETCH_SECONDS, cancelled: -> { false })
      return [] unless session&.id

      own = ContextSources.session_location(session.id, state_dir: state_dir)
      return [] if own.candidates.empty? || !OwnerPrompt.turn?(session: session, author: author)

      # The earlier owner prompts too: a proposal that came while one ran
      # (the REPL's plugins never see a running turn's prompt).
      texts = owner_texts(session.messages) + (prompt.is_a?(String) ? [prompt] : [])
      found = hits(texts, proposed(session.id, project_root: session.project_root, state_dir: state_dir))
      names = found.filter_map { |hit| attach(hit, own: own, state_dir: state_dir) }
      first_fetch(own, unfetched(own, names), cwd: session.working_directory, seconds: seconds, cancelled: cancelled)
      names
    rescue StandardError => e
      Log.warn(:context, "candidates_turn_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      []
    end

    # The REPL's turn start (it has no ContextAbsorber running): the notes
    # of the sources attached from candidates, as the worker's absorb gives
    # them, added to +engine+'s session and marked delivered.
    # @return [Integer] how many notes were added
    def deliver_notes(engine, session, state_dir: nil)
      own = ContextSources.session_location(session.id, state_dir: state_dir)
      names = own.candidates.map(&:name)
      return 0 if names.empty?

      absorber = ContextAbsorber.new(session_id: session.id, state_dir: state_dir, project_root: session.project_root)
      batch = absorber.pending or return 0
      picked = batch.deliveries.select { |delivery| names.include?(delivery.name) }
      picked.each { |delivery| engine.add_context_note(session, delivery.note) if delivery.note }
      absorber.commit(batch.with(deliveries: picked))
      picked.count(&:note)
    end

    # A late proposal (ctx.context.propose, after the owner's prompts):
    # attached now when one of them mentions it; the session's next turn
    # delivers its note.
    # @return [String, nil] the name attached
    def after_propose(candidate, own:, messages:, state_dir: nil)
      hit = hits(owner_texts(messages), [candidate]).first or return nil

      attach(hit, own: own, state_dir: state_dir)
    end

    # The session sources from candidates (+names+, and any other
    # candidate's source) never tried yet.
    def unfetched(own, names)
      wanted = (names + own.candidates.map(&:name)).uniq
      wanted.filter_map do |name|
        source = own.source(name) or next
        next if source.push? || own.snapshot(name).checked_at

        ContextSources::Attached.new(source: source, location: own, shadowed: false)
      end
    end

    # Runs each source's first fetch, all within +seconds+; one a poller
    # fetches meanwhile (:busy) is waited for. Cut short, a fetch records
    # nothing (the poller tries it soon); the note then comes later.
    def first_fetch(own, list, cwd:, seconds:, cancelled:)
      return if list.empty?

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      over = -> { cancelled.call || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline }
      list.each do |attached|
        outcome = ContextFetch.fetch(attached, cwd: cwd, cancelled: over)
        sleep(0.05) while outcome.status == :busy && !own.snapshot(attached.name).checked_at && !over.call
        next unless over.call && !own.snapshot(attached.name).text?

        Log.info(:context, "candidate_first_fetch_late", name: attached.name, seconds: seconds)
      end
    end
  end
end
