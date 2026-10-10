# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "atomic_file"
require_relative "session"
require_relative "session_inbox"
require_relative "worker_sidecar"
require_relative "log"
require_relative "tools/delegate_cursor"

module Samagotchi
  # Loaded on first use: session_manager requires terminal_ui, which
  # requires KernelLoop and so the tools (a require cycle otherwise).
  autoload :SessionManager, File.expand_path("session_manager", __dir__)
  # SessionContinue::OpenChild, the rows a plan refuses: loaded on first use too.
  autoload :SessionContinue, File.expand_path("session_continue", __dir__)

  # A continue moving the previous link's open delegates to the chain's new
  # link (SessionManager.continue_session), instead of archiving them with
  # it. A moved child gets a parent override (Session::PARENT_FILE), never a
  # rewritten session file, so its live worker saving a stale copy changes
  # nothing; its worker reads the override for its rings and at each turn's
  # start (Bridge::FEATURES "reparent").
  #
  # #apply runs between the new link's save and its worker's spawn, while
  # the link is #mark_starting (a ring from a moved child must not spawn a
  # second worker from the child's process until the link's own holds it).
  # Each step is idempotent,
  # and an intent file (INTENT_FILE) in the new link's folder names the move
  # until it is done: a worker that starts and finds one finishes the move
  # (#adopt), and a failed continue moves the same children back.
  module ChildMove
    # <new link dir>/move.json: {from, ids, noted}, while a move is under way.
    INTENT_FILE = "move.json"
    # <new link dir>/starting: {pid, at}, from the move to the worker's spawn.
    STARTING_FILE = "starting"
    # A starting marker older than this, or whose process is gone, is left
    # over from a continue that died: it holds nothing back.
    STARTING_STALE = 60.0
    # Who the note to a moved child is from (ContextNote's label).
    NOTE_SOURCE = "session chain"
    # What a live child's worker must name in its sidecar to be moved.
    FEATURE = "reparent"

    # What a continue does with the previous link's children: +move+ the
    # direct children whose subtree has an open node (they go to the new
    # link, their subtrees with them), +refuse+ the open ones it can't move
    # (SessionContinue::OpenChild, why: an older chi worker or a chi REPL).
    Plan = Data.define(:move, :refuse)
    # A move under way: from the session, the children moved, and those
    # already sent their note (so a move finished again notes no one twice).
    Intent = Data.define(:from, :ids, :noted) do
      def initialize(from:, ids:, noted: []) = super
    end

    module_function

    # @param open [Array<SessionContinue::OpenChild>] the previous link's open
    #   nodes, at any depth (SessionContinue.open_children)
    # @return [Plan]
    def plan(prev_id, open:, state_dir:)
      open_ids = open.map(&:id)
      move = []
      refuse = []
      SessionManager.children_of(prev_id, state_dir: state_dir).each do |row|
        subtree = [row[:id], *SessionManager.descendant_ids(row[:id], state_dir)]
        next if (subtree & open_ids).empty?

        if row[:archived]
          # An open delegate below an archived one: the archive's cascade
          # would take it, the move doesn't (only unarchived ones move).
          refuse.concat(open.select { |c| subtree.include?(c.id) }.map do |c|
            c.with(why: "under archived #{row[:id][0, 8]}; unarchive that one or archive this one")
          end)
          next
        end

        why = unmovable(row[:id], state_dir: state_dir)
        if why
          refuse << SessionContinue::OpenChild.new(id: row[:id], short_id: row[:id][0, 8], why: why)
        else
          move << row[:id]
        end
      end
      Plan.new(move: move, refuse: refuse)
    end

    # Why a child's live owner keeps it from moving: a chi REPL holds its
    # own Session and never reads the override; a worker on an older chi
    # neither. A worker with no sidecar yet is starting, on the newest chi
    # installed (SessionManager.worker_command): it moves.
    # @return [String, nil]
    def unmovable(child_id, state_dir:)
      owner = SessionManager.session_owner(child_id, state_dir: state_dir) or return nil
      return "open in a chi REPL; close it there" if owner.tui?

      sidecar = WorkerSidecar.live(Session.session_dir(child_id, state_dir: state_dir), unlink: false)
      return nil if sidecar.nil? || sidecar.features.include?(FEATURE)

      "older chi worker#{" #{sidecar.version}" if sidecar.version}; restart it"
    end

    # Move +ids+ (direct children of +from+) to +to+: the intent, the
    # cursors +to+ lacks (delegates.json), the overrides, the rings waiting
    # in +from+'s children/, a note to each child, then the intent goes.
    # Safe to run again on the same move: the intent records each child
    # noted, and a run finishing it (#adopt) notes only the rest. A crash
    # between a note and its record notes that child twice (better than
    # none).
    # @param undo [Boolean] a failed continue moving them back: its note says so
    def apply(ids, from:, to:, state_dir:, undo: false)
      return if ids.empty?

      intent = Intent.new(from: from, ids: ids)
      left = read_intent(to, state_dir: state_dir)
      intent = intent.with(noted: left.noted & ids) if left && left.from == from && left.ids.sort == ids.sort
      write_intent(to, intent, state_dir: state_dir)
      copy_cursors(ids, from: from, to: to, state_dir: state_dir)
      ids.each { |id| Session.reparent(id, to: to, from: from, state_dir: state_dir) }
      move_rings(ids, from: from, to: to, state_dir: state_dir)
      (ids - intent.noted).each do |id|
        note_child(id, to: to, undo: undo, state_dir: state_dir)
        intent = intent.with(noted: intent.noted + [id])
        write_intent(to, intent, state_dir: state_dir)
      end
      clear_intent(to, state_dir: state_dir)
      Log.info(:worker, undo ? "delegates_moved_back" : "delegates_moved", from: from[0, 8], to: to[0, 8], count: ids.size)
    end

    # The rings in +from+'s children/ from children whose parent is +to+
    # now (a failed continue's link, before it is deleted: a child that
    # read the override just before the undo rang it).
    def return_rings(from:, to:, state_dir:)
      ids = SessionInbox.find_ring_files(Session.session_dir(from, state_dir: state_dir)).filter_map do |file|
        id = SessionInbox.read_ring(file)&.dig(:child_id)
        id if Session.valid_id?(id) && Session.parent_override(id, state_dir: state_dir) == to
      end
      move_rings(ids.uniq, from: from, to: to, state_dir: state_dir)
    end

    # A worker starting for +session_id+ finishes a move its continue left
    # half done (the intent file is still there): only those children, never
    # the predecessor's others.
    # @return [Array<String>] the ids moved, [] with no intent
    def adopt(session_id, state_dir:)
      intent = read_intent(session_id, state_dir: state_dir) or return []
      apply(intent.ids, from: intent.from, to: session_id, state_dir: state_dir)
      intent.ids
    rescue StandardError => e
      Log.warn(:worker, "delegates_adopt_failed", sid: session_id[0, 8], error: e.class.name, msg: e.message)
      []
    end

    # @return [Intent, nil]
    def read_intent(session_id, state_dir:)
      data = JSON.parse(File.read(File.join(Session.session_dir(session_id, state_dir: state_dir), INTENT_FILE)))
      return nil unless data.is_a?(Hash) && Session.valid_id?(data["from"]) && data["ids"].is_a?(Array)

      noted = data["noted"].is_a?(Array) ? data["noted"].select { |id| Session.valid_id?(id) } : []
      Intent.new(from: data["from"], ids: data["ids"].select { |id| Session.valid_id?(id) }, noted: noted)
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def write_intent(session_id, intent, state_dir:)
      dir = Session.session_dir(session_id, state_dir: state_dir)
      FileUtils.mkdir_p(dir)
      AtomicFile.write(File.join(dir, INTENT_FILE), JSON.generate({ "from" => intent.from, "ids" => intent.ids, "noted" => intent.noted }))
    end

    def clear_intent(session_id, state_dir:)
      FileUtils.rm_f(File.join(Session.session_dir(session_id, state_dir: state_dir), INTENT_FILE))
    end

    def copy_cursors(ids, from:, to:, state_dir:)
      cursors = Tools::DelegateCursors.read(from, state_dir: state_dir).slice(*ids)
      Tools::DelegateCursors.merge(to, cursors, state_dir: state_dir)
    end

    # A ring keeps its file name (its time orders the rings).
    def move_rings(ids, from:, to:, state_dir:)
      rings = SessionInbox.find_ring_files(Session.session_dir(from, state_dir: state_dir)).select do |file|
        ids.include?(SessionInbox.read_ring(file)&.dig(:child_id))
      end
      return if rings.empty?

      dir = File.join(Session.session_dir(to, state_dir: state_dir), SessionInbox::CHILDREN_DIR)
      FileUtils.mkdir_p(dir)
      rings.each do |file|
        File.rename(file, File.join(dir, File.basename(file)))
      rescue Errno::ENOENT
        nil # taken meanwhile
      end
    end

    # The child's system prompt names the parent it started with for its
    # whole life (a prompt-cache miss each time it changed): a note tells a
    # running one where its notes and reports go now.
    def note_child(child_id, to:, state_dir:, undo: false)
      text = if undo
               "Your parent session is #{to[0, 8]} (#{to}) again: the continue that moved you to its next link " \
                 "failed. Send notes there, and your reports reach it."
             else
               "Your parent session is now #{to[0, 8]} (#{to}), the next link of its session chain: send notes " \
                 "there, and your reports reach it."
             end
      SessionInbox.write_note(child_id, text: text, source: NOTE_SOURCE, state_dir: state_dir)
    end

    # Hold off a worker for the continue's new link (#starting?) until its
    # own worker holds it: written before the move, removed by that worker
    # once it has the owner lock (Worker#start).
    def mark_starting(session_id, state_dir:)
      dir = Session.session_dir(session_id, state_dir: state_dir)
      FileUtils.mkdir_p(dir)
      AtomicFile.write(File.join(dir, STARTING_FILE), JSON.generate({ "pid" => Process.pid, "at" => Time.now.iso8601(3) }))
    end

    def clear_starting(session_id, state_dir:)
      FileUtils.rm_f(File.join(Session.session_dir(session_id, state_dir: state_dir), STARTING_FILE))
    end

    # Whether a continue is moving delegates to +session_id+ right now: its
    # marker is there, fresh, and the process that wrote it runs.
    def starting?(session_id, state_dir:)
      file = File.join(Session.session_dir(session_id, state_dir: state_dir), STARTING_FILE)
      return false unless File.exist?(file)

      data = JSON.parse(File.read(file))
      return false if Time.now - Time.iso8601(data["at"].to_s) > STARTING_STALE

      process_alive?(data["pid"].to_i)
    rescue JSON::ParserError, ArgumentError, SystemCallError
      false
    end

    # Signal 0 only asks whether the process exists.
    def process_alive?(pid)
      return false unless pid.positive?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
  end
end
