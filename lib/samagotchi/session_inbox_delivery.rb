# frozen_string_literal: true

require_relative "session"
require_relative "session_inbox"
require_relative "archive_store"
require_relative "worker_presence"

module Samagotchi
  # Loaded on first use: this autoload keeps SessionManager and its ~80
  # files unloaded until a delivery starts a worker.
  autoload :SessionManager, File.expand_path("session_manager", __dir__)

  # The session inbox's one delivery path (SessionInbox.deliver): which link
  # a delivery goes to (Head), whether it is refused, its write (the kind's
  # own writer, unchanged), one read of the worker's presence after it, and
  # what that means for a worker (WakePolicy). Loaded on first use, from
  # session_inbox.rb's autoloads: the bundle test kit's load budget
  # (spec/samagotchi/testing/sandbox_spec.rb) stays as it was.
  module SessionInbox
    # Where a delivery for +asked+ goes: +id+, reached +via+ :pinned (the
    # kind never follows a chain), :same (followed, nothing to follow) or
    # :head (a later link of +asked+'s chain).
    Resolved = Data.define(:id, :asked, :via)

    # A delivery's outcome.
    # @!attribute kind [Symbol] the WakePolicy row
    # @!attribute id [String] the session whose worker the outcome is about
    #   (a ring's file stays with +asked+: WakePolicy#resolves :reader)
    # @!attribute asked [String] the id the caller named
    # @!attribute via [Symbol] Resolved#via
    # @!attribute status [Symbol] :refused (nothing written), :queued (a
    #   worker sees it: one runs, is starting or was started) or :waits (no
    #   worker comes: it waits for the next start)
    # @!attribute wake [Symbol] WakePolicy#decide's outcome, :woken for a
    #   start made, or the refusal (:gone, :owned: a one-turn chi run's,
    #   :scratch)
    # @!attribute queued [Integer, nil] notes waiting (a note kind's), nil else
    Delivered = Data.define(:kind, :id, :asked, :via, :status, :wake, :queued) do
      def initialize(kind:, id:, asked:, via:, status:, wake:, queued: nil) = super

      def refused? = status == :refused
    end

    # What a delivery of one kind may do to a session's worker: one frozen
    # row per kind (ROWS), decided on WorkerPresence's predicates alone, in
    # one order for every kind (#decide).
    # @!attribute kind [Symbol] :send, :note, :push, :ring, :fresh_verdict or
    #   :leave (WorkerBoot's respawn, not a delivery)
    # @!attribute resolves [Symbol] which link it goes to (Head.resolve):
    #   :pinned the id named; :head the chain's newest link from it; :reader
    #   the link that reads the named one's file (a ring: the file stays with
    #   the parent parent.json names, ChildReports reads its predecessor's
    #   rings, so the wake goes one hop at most)
    # @!attribute starts [Boolean] it may start a worker
    # @!attribute unstops [Boolean] it starts a stopped session (a resume
    #   clears the stop): send only
    # @!attribute starts_archived [Boolean] it starts an archived link
    #   (input from a person un-archives it): send only
    # @!attribute refuse_tui [Boolean] a one-turn chi run's session refuses it
    # @!attribute refuse_scratch [Boolean] a chi scratch session refuses it
    WakePolicy = Data.define(:kind, :resolves, :starts, :unstops, :starts_archived, :refuse_tui, :refuse_scratch) do
      # @return [WakePolicy]
      # @raise [ArgumentError] no such kind
      def self.for(kind) = WakePolicy::ROWS.fetch(kind) { raise ArgumentError, "no inbox kind #{kind.inspect}" }

      # Why the delivery is refused before anything is written, else nil:
      # :gone (no session), :owned (a one-turn chi run's), :scratch.
      # @param load [#call, nil] the session, read only when the scratch
      #   flag decides (nil: not a scratch session)
      # @return [Symbol, nil]
      def refusal(presence, load: nil)
        return :gone unless presence.exists?
        return :owned if refuse_tui && presence.tui_owned?

        :scratch if refuse_scratch && scratch?(load)
      end

      # What the delivery means for the session's worker, in this order:
      # :gone, :owned (a one-turn chi run's), :live (a worker holds it: it
      # sees the delivery), :stopped (the stop marker: the only "stopped",
      # the file's status never decides), :archived, :starting (a worker is
      # being started: it reads the store on its first pass), :none (the
      # kind never starts one), :off (+wake+ false: none was asked),
      # :scratch (its terminal's alone; the file is read last, only here),
      # :start (start one).
      # @param wake [Boolean] the delivery asks for a worker (a ring in wake
      #   mode, a push with wake)
      # @return [Symbol]
      def decide(presence, wake: true, load: nil)
        return :gone unless presence.exists?
        return :owned if presence.tui_owned?
        return :live if presence.owned?
        return :stopped if presence.stop_marked? && !unstops
        return :archived if presence.archived? && !starts_archived
        # A stop cancels a start's hold-off for a kind that clears it
        # (WorkerPresence#start_pending?).
        return :starting if unstops ? presence.start_pending? : presence.starting?
        return :none unless starts
        return :off unless wake
        return :scratch if scratch?(load)

        :start
      end

      private def scratch?(load) = load ? load.call.scratch == true : false
    end

    WakePolicy::ROWS = {
      send: WakePolicy.new(kind: :send, resolves: :pinned, starts: true, unstops: true, starts_archived: true,
                           refuse_tui: true, refuse_scratch: true),
      note: WakePolicy.new(kind: :note, resolves: :head, starts: false, unstops: false, starts_archived: false,
                           refuse_tui: true, refuse_scratch: true),
      push: WakePolicy.new(kind: :push, resolves: :pinned, starts: true, unstops: false, starts_archived: false,
                           refuse_tui: false, refuse_scratch: false),
      ring: WakePolicy.new(kind: :ring, resolves: :reader, starts: true, unstops: false, starts_archived: false,
                           refuse_tui: false, refuse_scratch: false),
      fresh_verdict: WakePolicy.new(kind: :fresh_verdict, resolves: :pinned, starts: false, unstops: false,
                                    starts_archived: false, refuse_tui: false, refuse_scratch: false),
      # Not a delivery: a worker's own leave starting its successor for
      # what waits (input, rings) or a restart (WorkerBoot, after the
      # lock's release). A stop wins; an archived session's input still
      # starts it, as a send's would have.
      leave: WakePolicy.new(kind: :leave, resolves: :pinned, starts: true, unstops: false, starts_archived: true,
                            refuse_tui: false, refuse_scratch: false)
    }.freeze

    # Which link of a chain a delivery goes to.
    module Head
      module_function

      # +id+ for a pinned kind, or for an id not archived (the cheap check
      # first: only an archived id is walked, with one Session.list).
      # Else the walk forward over archived links that have a successor:
      # to the first link not archived, or the last (a loop a hand-edited
      # file could make ends where it started); a :reader kind goes one hop
      # at most.
      # @return [Resolved]
      def resolve(kind, id, state_dir:)
        how = WakePolicy.for(kind).resolves
        return Resolved.new(id: id, asked: id, via: :pinned) if how == :pinned

        same = Resolved.new(id: id, asked: id, via: :same)
        return same unless archived?(id, state_dir)

        nexts = successors(state_dir)
        seen = [id]
        while (following = nexts[seen.last]) && !seen.include?(following)
          seen << following
          break if how == :reader || !archived?(following, state_dir)
        end
        seen.size == 1 ? same : Resolved.new(id: seen.last, asked: id, via: :head)
      end

      def archived?(id, state_dir)
        Session.valid_id?(id) && ArchiveStore.archived?(Session.session_dir(id, state_dir: state_dir))
      end

      # id → the session that continues it (SessionChain.next_of's: the
      # earliest one, archived ones too).
      def successors(state_dir)
        Session.list(state_dir: state_dir, sort: "created_at", order: "asc", include_archived: true)
               .each_with_object({}) { |s, nexts| nexts[s.continues] ||= s.id if s.continues }
      end
    end

    # SessionInbox.deliver and SessionInbox.wake.
    module Dispatch
      # What a start each kind makes is logged as (SessionManager.start_for_inbox).
      START_EVENTS = { ring: :delegate_woke_parent, push: :context_woke_session }.freeze

      module_function

      # Deliver one +kind+ of thing to session +target+, in this order:
      # resolve the link (Head.resolve), refuse (WakePolicy#refusal: before
      # any write), write (the block: the kind's own writer, given the id
      # it writes under), read the presence once, then decide and apply
      # (#wake).
      # @param wake [Boolean] the delivery may ask for a worker; the block's
      #   value says whether it does (truthy: asks)
      # @param pin [Boolean] write under +target+ itself, whatever the kind's
      #   row resolves (a writer whose text is +target+'s own: an
      #   /objectives list built from its conversation)
      # @param resolved [Resolved, nil] the link, as the caller resolved it
      #   already (Head.resolve for this kind): not walked again
      # @param owner [#call, nil] (id) the owner lock's holder (a stand-in
      #   manager's session_owner); nil: SessionManager.session_owner
      # @param start [#call, nil] (id) starts a worker, returns :woken (or
      #   why not); nil: SessionManager.start_for_inbox
      # @yieldparam id [String] the session it is written under
      # @yieldreturn [Boolean] whether it asks for a worker
      # @return [Delivered]
      def deliver(kind, target, state_dir: nil, wake: true, pin: false, resolved: nil, owner: nil, start: nil)
        sd = state_dir || Session.default_state_dir
        policy = WakePolicy.for(kind)
        resolved = Resolved.new(id: target, asked: target, via: :pinned) if pin
        resolved ||= Head.resolve(kind, target, state_dir: sd)
        at = policy.resolves == :reader ? resolved.asked : resolved.id
        if (why = refusal(policy, at, sd, owner))
          return Delivered.new(kind: kind, id: resolved.id, asked: resolved.asked, via: resolved.via, status: :refused,
                               wake: why)
        end

        asks = yield(at)
        apply(policy, resolved, sd, wake: wake && asks ? true : false, owner: owner, start: start)
      end

      # The wake half of #deliver alone, for a delivery already on disk (a
      # failed continue's previous link with rings that came meanwhile).
      # @return [Delivered]
      def wake(kind, target, state_dir: nil, owner: nil, start: nil)
        sd = state_dir || Session.default_state_dir
        apply(WakePolicy.for(kind), Head.resolve(kind, target, state_dir: sd), sd, wake: true, owner: owner,
                                                                                    start: start)
      end

      def refusal(policy, id, state_dir, owner)
        return :gone unless Session.exist?(id, state_dir: state_dir)
        return nil unless policy.refuse_tui || policy.refuse_scratch

        policy.refusal(presence(id, state_dir, owner), load: -> { Session.load(id, state_dir: state_dir) })
      end

      def apply(policy, resolved, state_dir, wake:, owner:, start:)
        id = resolved.id
        outcome = policy.decide(presence(id, state_dir, owner), wake: wake, load: -> { Session.load(id, state_dir: state_dir) })
        if outcome == :start
          outcome = if start
                      start.call(id)
                    else
                      SessionManager.start_for_inbox(id, state_dir: state_dir,
                                                                                                    event: START_EVENTS.fetch(policy.kind))
                    end
        end
        status = %i[live woken starting].include?(outcome) ? :queued : :waits
        Delivered.new(kind: policy.kind, id: id, asked: resolved.asked, via: resolved.via, status: status,
                      wake: outcome, queued: notes_waiting(policy, status, id, state_dir))
      end

      # A note's count of the notes waiting for a start (0 when a worker
      # sees them); nil for the other kinds.
      def notes_waiting(policy, status, id, state_dir)
        return nil unless policy.kind == :note
        return 0 unless status == :waits

        SessionInbox.find_new_note_files(Session.session_dir(id, state_dir: state_dir)).size
      end

      def presence(id, state_dir, owner)
        reader = owner ? -> { owner.call(id) } : -> { SessionManager.session_owner(id, state_dir: state_dir) }
        WorkerPresence.read(id, state_dir: state_dir, owner: reader)
      end
    end
  end
end
