# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "atomic_file"
require_relative "log"
require_relative "session"
require_relative "session_metrics"
require_relative "steer"
require_relative "verify_anchor"
require_relative "verify_fresh_origin"

module Samagotchi
  autoload :SessionManager, File.expand_path("session_manager", __dir__)

  # Verify fresh (docs/internals/participants.md, Verify fresh): an unclear
  # verdict checked again by a delegate child that sees only the claim, in
  # the parent session's own folder, with none of its history. The child's
  # field (VerifyFreshOrigin) makes every turn of a participant's child
  # theirs: their author, the boundary their grant has in the parent, their
  # cap counted across the parent and all their fresh children (.spend).
  #
  # LEDGER, in the parent's directory (never its conversation), has one
  # line per child started (child id, the verdict it checks, who asked):
  # the running check (one fresh child per verdict at a time) and the
  # spend rollup read it.
  module VerifyFresh
    LEDGER = "verify_fresh.jsonl"
    LOCK = "verify_fresh.lock"
    # The child's first message, after the claim.
    ASK = "Verify this claim against the files here. You have none of the original session's context. " \
          "End with a line `Verdict: confirmed|refuted|unclear — <one-line reason>`."
    # How long a child whose worker hasn't come up yet counts as running
    # (Tools::Delegate::STARTING_GRACE_SECONDS).
    STARTING_GRACE_SECONDS = 15

    # A start refused: the HTTP +status+, the error +code+ and its words.
    class Refused < StandardError
      attr_reader :status, :code

      def initialize(status, code, detail)
        @status = status
        @code = code
        super(detail)
      end
    end

    NOT_FOUND = "no Verify verdict with that check turn in this session"
    NOT_UNCLEAR = "only an unclear verdict can be verified fresh"
    RUNNING = "a fresh check of this claim is already running"
    BUSY = "a fresh check this requester started is still running: one at a time each"
    FULL = "this session has as many delegates running as it may (session.max_children): wait for one to finish"

    module_function

    # The child's first prompt: the claim, quoted, and the ask. Nothing of
    # the parent's conversation.
    def prompt_for(quote)
      claim = quote.to_s.lines.map { |line| "> #{line.chomp}" }.join("\n")
      "Claim:\n#{claim}\n\n#{ASK}"
    end

    # Starts a fresh child for the parent's unclear verdict +of+ (its
    # check_turn_id). +author+: the requester ("p:<id>"), nil for the
    # owner; +mode+: a participant's grant's mode in the parent
    # (ParticipantMode.live_for), saved on the child.
    # @return [Session] the child
    # @raise [Refused] no such verdict, not unclear, or a fresh check of it
    #   still runs
    def start(parent_id, of:, author:, mode: nil, state_dir: Session.default_state_dir, spawn: nil)
      parent = Session.load(parent_id, state_dir: state_dir)
      record = original(parent.verdicts, of) or raise Refused.new(404, "not_found", NOT_FOUND)
      raise Refused.new(409, "not_unclear", NOT_UNCLEAR) unless field(record, :verdict).to_s == "unclear"

      anchor = VerifyAnchor.from(field(record, :anchor)) or raise Refused.new(404, "not_found", NOT_FOUND)
      author = Steer.sender_author(author)
      origin = VerifyFreshOrigin.new(author: author, mode: author && mode.to_s, of: of, anchor: anchor)
      dir = Session.session_dir(parent.id, state_dir: state_dir)
      spawn ||= SessionManager.method(:spawn_session)
      locked(dir) do
        refuse_busy!(parent.id, of, author, state_dir)

        child = spawn.call(prompt: prompt_for(anchor.quote), working_directory: parent.working_directory,
                           model_name: parent.model_name, memories: [Session::DELEGATE_MEMORY],
                           parent_id: parent.id, delegate: true, verify_fresh: origin, state_dir: state_dir)
        append_ledger(dir, { "child_id" => child.id, "of" => of, "author" => author, "at" => Time.now.utc.iso8601(3) })
        child
      end
    end

    # Under the lock: one fresh check per verdict, one running fresh child
    # per requester (a participant or the owner: each start passes the cap
    # on saved spend, so parallel children would multiply it), and no more
    # running children of any kind than session.max_children.
    def refuse_busy!(parent_id, of, author, state_dir)
      fresh = running(parent_id, state_dir: state_dir)
      raise Refused.new(409, "fresh_running", RUNNING) if fresh.any? { |row| row[:of] == of }
      raise Refused.new(409, "fresh_busy", BUSY) if fresh.any? { |row| row[:author] == author }

      require_relative "tools/delegate"
      return if Tools::Delegate.running_children(parent_id, state_dir: state_dir).size < Tools::Delegate.max_children

      raise Refused.new(409, "children_full", FULL)
    end
    private_class_method :refuse_busy!

    # The parent's verdict +of+ names, never a fresh one (a fresh verdict
    # lands on its original's card; the original takes another check).
    def original(verdicts, of)
      Array(verdicts).find do |record|
        record.is_a?(Hash) && field(record, :check_turn_id) == of && !field(record, :fresh)
      end
    end

    # The fresh children of +parent_id+ running now, newest last: [{of:,
    # child_id:, author:}].
    def running(parent_id, state_dir: Session.default_state_dir)
      ledger(Session.session_dir(parent_id, state_dir: state_dir)).select do |row|
        child_running?(row[:child_id], state_dir)
      end
    end

    # What +author+ spent in the fresh children of +parent_id+ (their saved
    # analytics), but +except+'s (the child asking, whose own spend its
    # worker counts live).
    # @return [Float]
    def children_spend(parent_id, author, state_dir: Session.default_state_dir, except: nil)
      return 0.0 unless Steer.participant_author?(author)

      ledger(Session.session_dir(parent_id, state_dir: state_dir)).sum(0.0) do |row|
        next 0.0 unless row[:author] == author && row[:child_id] != except

        SessionMetrics.saved_spend(Session.session_dir(row[:child_id], state_dir: state_dir), author)
      end
    end

    # What +author+ spent outside +session+'s own metrics that counts
    # against their cap there: in a parent, their fresh children's; in a
    # fresh child, the parent's and its other fresh children's.
    # @return [Float]
    def related_spend(session, author, state_dir: Session.default_state_dir)
      return 0.0 unless Steer.participant_author?(author) && session

      if session.verify_fresh && session.parent_id
        parent_dir = Session.session_dir(session.parent_id, state_dir: state_dir)
        SessionMetrics.saved_spend(parent_dir, author) +
          children_spend(session.parent_id, author, state_dir: state_dir, except: session.id)
      else
        children_spend(session.id, author, state_dir: state_dir)
      end
    rescue StandardError => e
      Log.warn(:worker, "fresh_spend_failed", error: e.class.name, msg: e.message)
      0.0
    end

    # The LEDGER's rows: [{child_id:, of:, author:}].
    def ledger(session_dir)
      path = File.join(session_dir, LEDGER)
      return [] unless File.exist?(path)

      File.readlines(path, chomp: true).filter_map do |line|
        row = JSON.parse(line)
        next unless row.is_a?(Hash) && Session.valid_id?(row["child_id"].to_s)

        { child_id: row["child_id"], of: row["of"].to_s, author: row["author"] }
      rescue JSON::ParserError
        nil
      end
    rescue SystemCallError
      []
    end

    def append_ledger(session_dir, row)
      FileUtils.mkdir_p(session_dir)
      File.open(File.join(session_dir, LEDGER), File::WRONLY | File::APPEND | File::CREAT, 0o600) do |io|
        io.write("#{JSON.generate(row)}\n")
      end
    end
    private_class_method :append_ledger

    # One start at a time per parent: the running check and the spawn.
    def locked(session_dir)
      FileUtils.mkdir_p(session_dir)
      File.open(File.join(session_dir, LOCK), File::RDWR | File::CREAT, 0o600) do |io|
        io.flock(File::LOCK_EX)
        yield
      end
    end
    private_class_method :locked

    # A child runs while its worker runs a turn, or while it is marked
    # running and its worker is on its way (Tools::Delegate.running?).
    def child_running?(child_id, state_dir)
      child = Session.summary_from_file(Session.session_file(child_id, state_dir: state_dir)) or return false
      return false unless child.status == Session::STATUS_RUNNING
      return true if SessionManager.session_owner(child_id, state_dir: state_dir)&.worker?

      Time.now - Time.iso8601(child.updated_at.to_s) < STARTING_GRACE_SECONDS
    rescue ArgumentError
      false
    end
    private_class_method :child_running?

    def field(record, key) = record[key] || record[key.to_s]
    private_class_method :field
  end
end
