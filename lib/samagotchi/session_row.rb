# frozen_string_literal: true

require "time"
require_relative "session"
require_relative "owner_lock"
require_relative "worker_link"
require_relative "recap_store"
require_relative "session_metrics"
require_relative "archive_store"
require_relative "effective_model"
require_relative "host_registry"

module Samagotchi
  # A session as the lists see it: the one row every listing builds and
  # reads (SessionManager.session_rows, chi sessions list on both backends,
  # the picker, list_sessions, a broadcast's recipients, a parent's
  # children, chi web's summaries route and Web::SessionSummary). Only
  # scalar facts that go on the wire: #to_summary_h is the summaries route's
  # body (28 keys, this order) and .from_summary_h reads it back, so a
  # remote row prints the same #cli_line as a local one.
  #
  # The liveness rule: +live+ is WorkerLink's worker_owned? (a worker holds
  # the lock, its Bridge up or on its way); +busy+ and +waiting+ need it,
  # +status+ is Session#displayed_status (a dead worker's "running" is idle).
  SessionRow = Data.define(:id, :desc, :preview, :title, :cwd, :project, :updated_at, :status, :saved_status, :live,
                           :busy, :owner, :recap, :auto_title, :ctx_pct, :parent_id, :continues, :delegate, :archived,
                           :scratch, :test_run, :stopped_by, :waiting, :waiting_id, :relayed_to)

  class SessionRow
    DESC_LIMIT = 60
    PREVIEW_LIMIT = 120
    # Seconds a child saved "running" with no worker yet counts as one on
    # its way (a worker boots in a few seconds): .running_or_starting?.
    STARTING_GRACE_SECONDS = 15

    # The summaries route's keys, in their order (#to_summary_h).
    SUMMARY_KEYS = %i[id short_id desc preview title cwd project updated_at status saved_status live busy owner recap
                      auto_title ctx_pct parent_id parent_short_id continues continues_short_id delegate archived
                      scratch test_run stopped_by waiting waiting_id relayed_to].freeze
    DERIVED_KEYS = %i[short_id parent_short_id continues_short_id].freeze
    # `chi sessions list --format json`'s keys (of SUMMARY_KEYS: no status).
    # owner: "worker", "tui" (a one-turn chi run: it takes no notes or
    # messages) or nil; recap: the saved recap's first sentence, or nil;
    # project: its git project's root, or nil; parent_id: the session that
    # delegated it (the delegate tool), or nil; delegate: started by the
    # delegate tool (a fork has a parent_id too); continues: the session it
    # continues (its chain's previous link), or nil; archived: hidden from
    # the lists (only with --archived can it be true); scratch: a `chi
    # scratch` session; ctx_pct: how full the context was after the last
    # turn, or nil; title: the session's own name (/title; desc shows it
    # too), or nil; auto_title: the one its recap gave it (RecapTitle), or
    # nil; waiting: the kind of question it waits on (question, approval,
    # hook), or nil; waiting_id: its id, for chi answer --question;
    # relayed_to: the parent session (short id) whose card it also waits in
    # (the approval relay), or nil.
    JSON_KEYS = %i[id short_id desc title auto_title cwd project updated_at live busy owner recap parent_id continues
                   delegate archived scratch ctx_pct waiting waiting_id relayed_to stopped_by].freeze

    # @param session [Session] a saved session
    # @param session_dir [String] its folder
    # @param owner [OwnerLock::Owner, nil] the lock's holder as read
    #   (SessionManager.session_owner)
    # @param link [WorkerLink outcome, nil] resolved with +owner+; nil:
    #   resolved here (one read of bridge.json)
    # @param roots [Hash] ProjectScope.root_for's cache, shared by a listing
    # @param budgets [#call] (session) -> its llm_context budget (.budgets:
    #   one HostRegistry per listing)
    # @param saved [SessionMetrics::SavedSummary, nil, :read] the saved
    #   analytics as a caller already read it; :read reads it here
    # @param card [RecapStore::Card, :read] the recap card, likewise
    # @return [SessionRow]
    def self.build(session, session_dir:, owner:, link: nil, roots: {}, budgets: SessionRow.budgets, saved: :read,
                   card: :read)
      link ||= WorkerLink.resolve(session_dir, unlink: false, owner: owner)
      live = link.worker_owned?
      card = RecapStore.card(session_dir) if card == :read
      if saved == :read
        saved = SessionMetrics.saved_summary(session_dir, budget_tokens: -> { budgets.call(session) })
      end
      waiting = session.waiting_question(live: live)
      new(id: session.id, desc: desc_of(session), preview: cut(summary_text(session), PREVIEW_LIMIT),
          title: session.title, cwd: session.working_directory, project: session.project_root(cache: roots),
          updated_at: session.updated_at, status: session.displayed_status(owner: owner), saved_status: session.status,
          live: live, busy: live && session.status == Session::STATUS_RUNNING, owner: owner&.kind,
          recap: card.preview, auto_title: card.title, ctx_pct: saved&.ctx_pct&.round(1),
          parent_id: session.parent_id, continues: session.continues, delegate: session.delegate?,
          archived: ArchiveStore.archived?(session_dir), scratch: session.scratch, test_run: session.test_run,
          stopped_by: session.stopped_by, waiting: waiting&.dig(:kind), waiting_id: waiting&.dig(:id),
          relayed_to: waiting&.dig(:relayed_to))
    end

    # A row read back from #to_summary_h's hash (symbol keys; a remote's
    # rows, Remote#symbolize'd). A key the hash lacks reads nil.
    def self.from_summary_h(hash)
      new(**members.to_h { |key| [key, hash[key]] })
    end

    # The budget resolver a listing shares: the process's HostRegistry
    # (HostRegistry.current), taken on the first row that needs it (a saved
    # context to count) and kept for the rest of the listing.
    # @return [#call] (session) -> the session's budget in tokens or nil
    def self.budgets
      registry = nil
      ->(session) { EffectiveModel.session_budget(session, registry: registry ||= HostRegistry.current) }
    end

    # Busy (a worker runs its turn), or saved running with no worker yet
    # for less than STARTING_GRACE_SECONDS: a worker on its way (it counts
    # against session.max_children; Verify fresh waits for it). The
    # displayed status shows that one as idle, so +saved_status+ is the
    # file's.
    def self.running_or_starting?(saved_status:, live:, busy:, updated_at:)
      return true if busy
      return false unless saved_status == Session::STATUS_RUNNING && !live

      Time.now - Time.iso8601(updated_at.to_s) < STARTING_GRACE_SECONDS
    rescue ArgumentError
      false
    end

    # A session as one line of text for the lists: its title (/title), else
    # its last prompt, else the first message it was started with (a session
    # command like `/model x`, or a first turn not saved yet).
    def self.summary_text(session)
      return one_line(session.title) unless session.title.to_s.strip.empty?

      one_line(session.last_prompt.to_s.strip.empty? ? session.first_preview.to_s : session.last_prompt.to_s)
    end

    # A prompt as one line for a session list: whitespace collapsed, and a
    # quoted or annotated message (ContextQuote, the web's annotations)
    # without its "> " markers, so the words show.
    def self.one_line(text)
      text.to_s.gsub(/^[ \t]*(?:>[ \t]?)+/, "").gsub(/\s+/, " ").strip
    end

    # "<cwd basename> · <last prompt, or the first preview>", one line.
    # The flags a list line carries: a chi scratch session, a test run, an
    # archived one, and the turn's stopper: "[looped]" for loop-guard (the
    # bundle's thinking watch, and the word `chi sessions stats` uses for
    # its cuts), "[stopped by X]" for any other hook (a cut with no retry
    # left records the same stopped_by).
    def self.flags(scratch:, test_run:, archived:, stopped_by: nil)
      flag = if scratch
               " [scratch]"
             else
               (test_run ? " [test]" : "")
             end
      flag += " [archived]" if archived
      return flag if stopped_by.to_s.empty?

      flag + (stopped_by.to_s == "loop-guard" ? " [looped]" : " [stopped by #{stopped_by}]")
    end

    def self.desc_of(session)
      desc = [File.basename(session.working_directory.to_s), summary_text(session)].reject(&:empty?).join(" · ")
      cut(desc, DESC_LIMIT)
    end
    private_class_method :desc_of

    def self.cut(text, limit)
      text.length > limit ? "#{text[0, limit - 1]}…" : text
    end
    private_class_method :cut

    def short_id = id.to_s[0, 8]
    def parent_short_id = parent_id&.[](0, 8)
    def continues_short_id = continues&.[](0, 8)

    def running_or_starting?
      self.class.running_or_starting?(saved_status: saved_status, live: live, busy: busy, updated_at: updated_at)
    end

    # The session as `chi sessions list` prints it, wherever it runs (the
    # plain list, the --live/--cwd text, a remote's): its id, state (a
    # question it waits on, else the displayed status), the context's fill,
    # updated_at, its text (a title, else the recap's auto title or first
    # sentence, else the last prompt; 60 characters), its flags, and the
    # parent it was delegated from (↳) and the link it continues (↪). Reads
    # only row fields, so a remote row prints the same line.
    def cli_line
      state = if relayed_to then "waiting (in parent #{relayed_to})"
              elsif waiting then "waiting"
              else status.to_s
              end
      text = (title ? preview : auto_title || recap || preview).to_s[0, DESC_LIMIT]
      links = parent_short_id ? "  ↳ #{parent_short_id}" : ""
      links += "  ↪ #{continues_short_id}" if continues_short_id
      ctx = SessionMetrics.context_label(ctx_pct)
      flag = self.class.flags(scratch: scratch, test_run: test_run, archived: archived, stopped_by: stopped_by)
      "#{id}  #{state.ljust(8)}  #{ctx.ljust(8)}  #{updated_at}  #{text}#{flag}#{links}"
    end

    # The summaries route's row: SUMMARY_KEYS, in order.
    # @return [Hash] symbol keys
    def to_summary_h
      SUMMARY_KEYS.to_h { |key| [key, public_send(key)] }
    end
  end
end
