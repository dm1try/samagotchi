# frozen_string_literal: true

require_relative "../session_inbox"
require_relative "../session_lifecycle"

module Samagotchi
  module SessionLifecycle
    # What a delivery's WakePolicy#decide outcome is as a cell: a worker
    # sees it (:live) or one is started (:start): go; it waits on disk for
    # whoever runs the session next: wait; :gone, :owned and :deleting (a
    # deleter holds the lock) are refusals. (:off and :scratch are
    # op-local: a delivery that asks no worker, a scratch session's file.)
    # A :shared row's delivery while a transition holds the lock
    # (SessionInbox::Hold, Delivered#wake) is :busy, or :continued when the
    # holder is a continue naming its new link (a resolution fact, as
    # continuing is: TRANSITIONING names :busy).
    DELIVERY_CELLS = { start: :go, live: :go, starting: :wait, stopped: :wait, archived: :wait, none: :wait,
                       gone: :gone, owned: :owned, deleting: :deleting, busy: :busy, continued: :continued }.freeze

    # The operations that are not inbox deliveries, in the order of LITERAL's
    # rows: resume_session, restart_session, stop_session, archive
    # (archivable!), delete (release_for_delete!, stop: false), a schedule's
    # busy check in chain and in same mode (Schedules#busy_reason), and a
    # terminal attaching (TerminalUI::LocalLink#live_worker).
    LITERAL_OPS = %i[resume restart stop archive delete sched_chain sched_same attach].freeze

    # What each literal operation answers in each state today, with neutral
    # op-local facts (not scratch, saved status idle, no input/, no question
    # or offer, not SIGSTOPped, features restart and activity, an idle worker
    # with no streams). For schedules, worker_busy is "its worker is starting
    # or leaving", deleting is DeliverResult::DELETING's detail, and
    # worker_newer is WorkerLink::Skew#short_message (Schedules::BusyPart's
    # BUSY_WORDS; Schedules#busy_cell reads these two columns). Resume's live is "a
    # worker holds it"; restart's fallback is its unresponsive-worker path,
    # its stop_marked a stop marked and its deleting a deleter holds the lock
    # (it reads this table: restart_session's precheck); attach's gone_* are
    # LocalLink's [:gone, why]. absent's delete and schedule cells are
    # unreachable (a gone session is refused before the gate). Resolution (a
    # chain's head, a continue's successor) stays outside: these are the
    # link's own.
    LITERAL = {
      absent: %i[gone gone gone gone go go go wait],
      tui_owned: %i[owned_by_tui owned_by_tui owned_by_tui owned_by_tui owned_by_tui go go wait],
      deleting: %i[live deleting go go worker_running deleting deleting wait],
      stopping: %i[live stop_marked go go worker_running stopped stopped gone_stopped],
      skew: %i[live fallback go go worker_running worker_newer worker_newer gone_worker_newer],
      leaving: %i[live not_running go go worker_running worker_busy worker_busy wait],
      booting_stuck: %i[live fallback go go worker_running worker_busy worker_busy wait],
      booting: %i[live starting go go worker_running worker_busy worker_busy wait],
      live: %i[live go go go worker_running go go go],
      stopped_starting: %i[go stop_marked go starting worker_running stopped stopped gone_stopped],
      stopped: %i[go stop_marked go go go stopped stopped gone_stopped],
      archived_starting: %i[starting not_running go starting worker_running worker_busy go wait],
      starting: %i[starting not_running go starting worker_running worker_busy go wait],
      archived: %i[go not_running go go go go go wait],
      idle: %i[go not_running go go go go go wait]
    }.freeze

    # {op => {state => cell}}: every operation in every state (STATES order).
    # The delivery columns are generated from SessionInbox::WakePolicy::ROWS
    # (each row's #decide on CANONICAL, wake asked, no scratch file), so a
    # row change moves its column; the literal columns are goldens of what
    # the deciders do, pinned by spec/session_lifecycle/matrix_spec.rb.
    ALLOWED = lambda do
      deliveries = SessionInbox::WakePolicy::ROWS.to_h do |kind, policy|
        [kind, STATES.to_h { |state| [state, DELIVERY_CELLS.fetch(policy.decide(CANONICAL.fetch(state), wake: true, load: nil))] }.freeze]
      end
      literal = LITERAL_OPS.each_with_index.to_h do |op, index|
        [op, STATES.to_h { |state| [state, LITERAL.fetch(state).fetch(index)] }.freeze]
      end
      deliveries.merge(literal).freeze
    end.call

    # {op => cell} for the operations that answer otherwise while a
    # transition holds the session's lock, in every state (it is a fact
    # beside the state, not one of STATES: any state can be held): each
    # delivery whose WakePolicy row holds :shared is refused :busy
    # (SessionInbox::Hold, before its own checks); a :none row answers its
    # state's cell. The literal operations read no transition lock yet.
    TRANSITIONING = SessionInbox::WakePolicy::ROWS.filter_map { |kind, policy| [kind, :busy] if policy.shared? }
                                                  .to_h.freeze
  end
end
