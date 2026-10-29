# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "securerandom"
require_relative "atomic_file"
require_relative "delivery"
require_relative "log"
require_relative "session"
require_relative "steer"
require_relative "turn_origin"

module Samagotchi
  # Loaded on first use (a Verify turn's input): keeps the bundle test kit's
  # load budget (spec/samagotchi/testing/sandbox_spec.rb).
  autoload :VerifyAnchor, File.expand_path("verify_anchor", __dir__)

  # A session directory's file inbox and outbox (see SessionManager for the
  # layout): input/ holds one JSON file per queued turn, notes/ the context
  # notes a worker adds between turns, output/ one text file per reply,
  # children/ the rings of delegate children that have news (ChildReports).
  # Writers are any process (the web, chi send, chi note, send_note); the
  # worker claims input and notes by renaming them to *.processing.
  module SessionInbox
    INPUT_DIR  = "input"
    # Context notes live apart from input/, so nothing that reads input/
    # (the mid-turn drain, the idle-exit hold, the Waker) ever sees one.
    NOTES_DIR  = "notes"
    NOTE_MAX_BYTES = 16 * 1024
    OUTPUT_DIR = "output"
    # A delegate child's doorbell: "look at me", not the report itself.
    CHILDREN_DIR = "children"
    # Input-file format this worker reads (JSON with the sender's ids and
    # images: refs), advertised in the Bridge sidecar so a chi from before
    # it (one that wrote plain .txt to a worker not advertising 2, or held
    # images back below 3) writes what this one reads.
    INPUT_FORMAT = 3

    # A note (or a `chi send` message) that can't go in: empty, or over
    # NOTE_MAX_BYTES.
    class NoteRejected < ArgumentError; end

    # Queue a turn's input file: JSON with the prompt and the sender's ids.
    # +delivery+ is only written when it is "queue": a step-boundary
    # message is the default an older worker assumes, and a cut is done by
    # the sender (the Bridge) at once, not by the file.
    # @param client_id [String, nil] the sending UI
    # @param enqueued_id [String, nil] the id its ACK / :turn_enqueued carry
    # @param delivery [String, nil] the wire value: "next_step" (default),
    #   "cut" or "queue"
    # @param images [Array<Hash>] image refs ({file:, name:}) in the
    #   session's images/
    # @param author [String, nil] who wrote the message when it isn't the
    #   session's owner (Web::Principal#author); nil, the owner's, is never
    #   written, so an owner's file is as it always was
    # @param now [Time] the time the file is named by (a spec's clock)
    # @return [String, false] the input file's path, or false
    def self.write_input(session_dir, prompt:, client_id: nil, enqueued_id: nil, no_interrupt: false, images: [],
                         delivery: nil, author: nil, verify: nil, now: Time.now)
      images = Array(images)
      input_dir = File.join(session_dir, INPUT_DIR)
      FileUtils.mkdir_p(input_dir)

      path = File.join(input_dir, "#{now.strftime("%Y%m%d%H%M%S%9N")}.json")
      record = { "prompt" => prompt.to_s, "client_id" => client_id, "enqueued_id" => enqueued_id,
                 "no_interrupt" => (no_interrupt ? true : nil),
                 "delivery" => (Delivery.queue?(delivery) ? Delivery::QUEUE : nil),
                 "images" => (images.empty? ? nil : images.map { |image| image.transform_keys(&:to_s) }),
                 "author" => author, "verify" => VerifyAnchor.from(verify)&.to_file }.compact
      AtomicFile.write(path, JSON.generate(record))
      path
    rescue StandardError
      false
    end

    # Queue a context note for a session: background text its worker adds
    # to the conversation between turns. It never starts a turn.
    # @param source [String] where it came from ("cli", "slack", "session")
    # @param from_session [String, nil] the sending session, for a peer's note
    # @param now [Time] the time the file is named and stamped by (a spec's clock)
    # @return [String] the note file's path
    # @raise [NoteRejected] for an empty note or one over 16 KiB (never cut)
    def self.write_note(session_id, text:, source: "cli", from_session: nil, from_cwd: nil, state_dir: nil,
                        now: Time.now)
      body = checked_text(text)
      sd = state_dir || Session.default_state_dir
      notes_dir = File.join(Session.session_dir(session_id, state_dir: sd), NOTES_DIR)
      FileUtils.mkdir_p(notes_dir)

      # The random part keeps two writers in one nanosecond apart; the
      # timestamp keeps the names in arrival order.
      name = "#{now.strftime("%Y%m%d%H%M%S%9N")}-#{SecureRandom.hex(3)}.json"
      path = File.join(notes_dir, name)
      record = { "text" => body, "source" => source.to_s, "from_session" => from_session,
                 "from_cwd" => from_cwd, "created_at" => now.iso8601 }.compact
      AtomicFile.write(path, JSON.generate(record))
      path
    end

    # The same empty and 16 KiB checks for a note and a sent message.
    # @param noun [String] what the errors call the text
    # @return [String] the stripped text
    # @raise [NoteRejected]
    def self.checked_text(text, noun: "note")
      body = text.to_s.strip
      raise NoteRejected, "the #{noun} is empty" if body.empty?
      if body.bytesize > NOTE_MAX_BYTES
        raise NoteRejected, "the #{noun} is #{body.bytesize} bytes; the limit is 16 KiB (#{NOTE_MAX_BYTES} bytes)"
      end

      body
    end

    # Queued notes, oldest first, plus any a crashed worker claimed and left
    # (the absorber skips a note id the conversation already holds).
    def self.find_new_note_files(session_dir)
      notes_dir = File.join(session_dir, NOTES_DIR)
      return [] unless Dir.exist?(notes_dir)

      Dir.glob(File.join(notes_dir, "*.{json,json.processing}")).sort_by { |p| File.basename(p) }
    end

    # @return [String, nil] the claimed path, or nil when another claimed it
    def self.claim_note_file(note_file)
      return note_file if note_file.end_with?(".processing")

      claim_input_file(note_file)
    end

    # @return [Hash, nil] {note_id:, text:, source:, from_session:, from_cwd:,
    #   created_at:}, or nil for a file that holds no usable note
    def self.read_note(note_file)
      data = JSON.parse(File.read(note_file))
      text = data["text"].to_s.strip
      return nil if text.empty?

      { note_id: File.basename(note_file).sub(/\.json(\.processing)?\z/, ""), text: text,
        source: data["source"].to_s.empty? ? "cli" : data["source"].to_s,
        from_session: data["from_session"], from_cwd: data["from_cwd"], created_at: data["created_at"] }
    rescue JSON::ParserError, SystemCallError, NoMethodError, TypeError
      nil
    end

    # Ring a parent: a file naming the child and why. The caller makes sure
    # the parent's session exists (no orphan dir for a deleted one).
    # @param why [String] "turn_end", "question" or "crash"
    # @return [String] the ring file's path
    def self.write_ring(session_dir, child_id:, why:)
      dir = File.join(session_dir, CHILDREN_DIR)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{Time.now.strftime("%Y%m%d%H%M%S%9N")}-#{child_id.to_s[0, 8]}.json")
      AtomicFile.write(path, JSON.generate({ "child_id" => child_id, "why" => why, "at" => Time.now.iso8601(3) }))
      path
    end

    # The rings waiting, oldest first.
    def self.find_ring_files(session_dir)
      dir = File.join(session_dir, CHILDREN_DIR)
      return [] unless Dir.exist?(dir)

      Dir.glob(File.join(dir, "*.json")).sort_by { |p| File.basename(p) }
    end

    # @return [Hash, nil] {child_id:, why:, at:}, nil for a file that holds none
    def self.read_ring(ring_file)
      data = JSON.parse(File.read(ring_file))
      return nil unless data.is_a?(Hash) && !data["child_id"].to_s.empty?

      { child_id: data["child_id"].to_s, why: data["why"].to_s, at: data["at"] }
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # A turn's reply: output/<timestamp>.txt, or
    # output/<timestamp>-<enqueued_id>.txt for a turn that ran an input
    # with an id, so a wait for that input's turn (ReplyWait's turn:) finds
    # its own reply. The names still sort by time ("-" sorts before ".",
    # so an id'd name and a bare one of the same timestamp keep order);
    # every reader globs *.txt.
    # @param enqueued_id [String, nil] the turn's input id (LastTurn#enqueued_id)
    # @param now [Time] the time the file is named by (a spec's clock)
    def self.write_output(session_dir, response, enqueued_id: nil, now: Time.now)
      output_dir = File.join(session_dir, OUTPUT_DIR)
      FileUtils.mkdir_p(output_dir)
      timestamp = now.strftime("%Y%m%d%H%M%S%9N")
      AtomicFile.write(File.join(output_dir, "#{output_name(timestamp, enqueued_id)}.txt"), response.to_s)
    end

    # An id that is safe in a file name (a Bridge's or deliver_turn's
    # uuid); anything else leaves the name bare.
    ENQUEUED_ID_NAME = /\A[A-Za-z0-9_-]{1,64}\z/

    def self.output_name(timestamp, enqueued_id)
      id = enqueued_id.to_s
      ENQUEUED_ID_NAME.match?(id) ? "#{timestamp}-#{id}" : timestamp
    end
    private_class_method :output_name

    # @return [String, nil] the reply filename of the turn that ran the
    #   input +enqueued_id+, or nil while it has none
    def self.reply_for(session_dir, enqueued_id)
      dir = File.join(session_dir, OUTPUT_DIR)
      id = enqueued_id.to_s
      return nil if id.empty? || !Dir.exist?(dir)

      suffix = "-#{id}.txt"
      Dir.children(dir).select { |f| f.end_with?(suffix) }.max
    end

    # The output files' text, oldest first; with +since_time+ only files
    # modified after it.
    def self.read_outputs(session_dir, since_time: nil)
      output_path = File.join(session_dir, OUTPUT_DIR)
      return [] unless Dir.exist?(output_path)

      Dir.glob(File.join(output_path, "*.txt")).sort.filter_map do |f|
        File.read(f) if since_time.nil? || File.mtime(f) > since_time
      end
    end

    def self.find_new_input_files(session_dir)
      input_dir = File.join(session_dir, INPUT_DIR)
      return [] unless Dir.exist?(input_dir)

      Dir.glob(File.join(input_dir, "*.json"))
    end

    # A claimed input file as read: its +prompt+, +origin+ (a TurnOrigin
    # from the file's client_id, enqueued_id and author; nil when it names
    # no sender), whether its turn runs with the raised iteration limit
    # (+no_interrupt+, --no-interrupt), its +images+ ({file:, name:} refs),
    # and its +delivery+ ("queue" or nil; a file without the key is one an
    # older chi wrote, so nil).
    Input = Data.define(:prompt, :origin, :no_interrupt, :images, :delivery, :verify) do
      def initialize(prompt:, origin: nil, no_interrupt: false, images: [], delivery: nil, verify: nil)
        super(prompt:, origin: TurnOrigin.of(origin), no_interrupt:, images:, delivery:, verify: verify && VerifyAnchor.from(verify))
      end
    end
    # A file that doesn't parse, or isn't a JSON object: no prompt.
    UNREADABLE_INPUT = Input.new(prompt: nil)

    # @return [Input] a claimed input file's contents; UNREADABLE_INPUT for
    #   one that isn't a JSON object
    def self.read_input(claimed_file)
      data = JSON.parse(File.read(claimed_file).to_s)
      return UNREADABLE_INPUT unless data.is_a?(Hash)

      # author: only a file that names one (an owner's names none).
      origin = TurnOrigin.from(data.slice("client_id", "enqueued_id", "author"))
      images = Array(data["images"]).select { |image| image.is_a?(Hash) }.map { |image| image.transform_keys(&:to_sym) }
      Input.new(prompt: data["prompt"].to_s, origin: origin, no_interrupt: data["no_interrupt"] == true,
                images: images, delivery: Delivery.queue?(data["delivery"]) ? Delivery::QUEUE : nil, verify: data["verify"])
    rescue JSON::ParserError
      UNREADABLE_INPUT
    end

    # Whether a mid-turn drain leaves this unclaimed input file for a turn
    # of its own instead of merging it at a step boundary: a queued message
    # (`delivery: queue`), an image message (steering merges text only), or
    # a participant's, whatever its delivery says: theirs always runs as its
    # own turn, never inside another author's (D6; chi web queues it, and
    # this is the worker's own layer).
    # The drain skips such a file without stopping at it, so a later text
    # line still merges; the drain's file filter reads this one predicate,
    # so what a boundary leaves changes in one place.
    def self.waits_for_turn_end?(input_file)
      data = JSON.parse(File.read(input_file))
      data.is_a?(Hash) && turn_end_data?(data)
    rescue JSON::ParserError, SystemCallError
      false
    end

    # Whether an unclaimed input file may be a participant's (it names a
    # participant author): what the worker holds while the owner's Continue
    # offer stands (Worker#run_input_files). An unreadable file counts:
    # holding it costs nothing (it runs no turn), running it unread could.
    def self.participant_input?(input_file)
      data = JSON.parse(File.read(input_file))
      !data.is_a?(Hash) || Steer.participant_author?(data["author"])
    rescue JSON::ParserError, SystemCallError
      true
    end

    # A parsed input file's #waits_for_turn_end?. A Verify turn waits too:
    # merged into a running turn as a steer, its anchor would be lost.
    def self.turn_end_data?(data)
      Array(data["images"]).any? || Delivery.queue?(data["delivery"]) || Steer.participant_author?(data["author"]) ||
        data["verify"].is_a?(Hash)
    end

    # Whether a message waits that a running turn's next boundary merges and
    # that a person (or chi send, or a delegating parent) sent: an unclaimed
    # input file not held for the turn's end (#turn_end_data?), with a
    # prompt, from a sender that may cut (Steer.cuts?). A running task_wait
    # ends on it (Worker#input_waiting?). It only peeks: nothing is claimed;
    # a file the drain or a dequeue claims meanwhile (ENOENT) or one that
    # doesn't parse is skipped.
    def self.steer_waiting?(session_dir)
      find_new_input_files(session_dir).any? do |file|
        data = JSON.parse(File.read(file))
        data.is_a?(Hash) && !turn_end_data?(data) && !data["prompt"].to_s.strip.empty? &&
          Steer.cuts?(Steer.source_for_client(data["client_id"]))
      rescue JSON::ParserError, SystemCallError
        false
      end
    end

    # How the unclaimed input file carrying +enqueued_id+ waits: :turn_end
    # (a queue or an image message: it runs as a turn of its own, never
    # merged, #waits_for_turn_end?), :merges (a running turn's drain may
    # take it as a steer), or nil when none waits.
    # @return [Symbol, nil]
    def self.waiting_input(session_dir, enqueued_id)
      data = waiting_input_data(session_dir, enqueued_id) or return nil
      turn_end_data?(data) ? :turn_end : :merges
    end

    # The unclaimed input file carrying +enqueued_id+, as parsed; nil when
    # none waits.
    # @return [Hash, nil]
    def self.waiting_input_data(session_dir, enqueued_id)
      id = enqueued_id.to_s
      return nil if id.empty?

      find_new_input_files(session_dir).each do |file|
        data = JSON.parse(File.read(file))
        return data if data.is_a?(Hash) && data["enqueued_id"] == id
      rescue JSON::ParserError, SystemCallError
        next
      end
      nil
    end

    def self.claim_input_file(input_file)
      processing_path = "#{input_file}.processing"
      File.rename(input_file, processing_path)
      processing_path
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    # Where a removed queued input leaves its tombstone: input/removed/<id>,
    # an empty file outside the *.json glob, so a wait for that input's
    # turn (ReplyWait's turn:) learns it will never run (#removed?).
    REMOVED_DIR = "removed"
    # The worker's sidecar feature for POST turn/dequeue (Bridge::FEATURES).
    UNQUEUE_FEATURE = "unqueue"

    # Take back the unclaimed input file carrying +enqueued_id+ before a
    # turn takes it (the Bridge's POST turn/dequeue, under the event log):
    # only one that waits for the turn's end (a queue or an image message,
    # #waits_for_turn_end?); a next-step file may be merged at any boundary.
    # Its tombstone is written first, then the file claimed as the drain
    # does (the rename is the race's one winner) and deleted; a claim a
    # turn won takes the tombstone back. Tombstone first: a ReplyWait look
    # that finds the file claimed and no tombstone knows a turn took it
    # (never a removal half done, which it would read as a merge).
    # @return [Array(Symbol, Input)] [:removed, the input it held],
    #   [:not_queued, nil] for a next-step file, [:claimed, nil] when a
    #   turn took it (its *.json.processing is there), [:none, nil] for
    #   none
    def self.take_queued_input(session_dir, enqueued_id)
      id = enqueued_id.to_s
      return [:none, nil] if id.empty?

      find_new_input_files(session_dir).sort.each do |file|
        data = JSON.parse(File.read(file))
        next unless data.is_a?(Hash) && data["enqueued_id"] == id
        return [:not_queued, nil] unless Array(data["images"]).any? || Delivery.queue?(data["delivery"])

        mark_removed(session_dir, id)
        unless (claimed = claim_input_file(file))
          unmark_removed(session_dir, id)
          return [:claimed, nil]
        end
        # The claimed file goes whatever the read does: a claimed file left
        # with the tombstone would read as a removal still under way
        # (ReplyWait) until the wait's timeout. One that can't be read was
        # still taken back (no prompt to give). A process killed between
        # the claim and this delete leaves both: that wait then times out,
        # never a wrong answer (a stale *.json.processing is never run).
        input = begin
          read_input(claimed)
        rescue SystemCallError
          UNREADABLE_INPUT
        ensure
          FileUtils.rm_f(claimed)
        end
        return [:removed, input]
      rescue JSON::ParserError, SystemCallError
        next
      end
      claimed_input?(session_dir, id) ? [:claimed, nil] : [:none, nil]
    end

    # The claimed input files (*.json.processing: a turn's, now or left by
    # a crash, or a removal's before it deletes it).
    # @return [Array<String>] their paths
    def self.claimed_input_files(session_dir) = Dir.glob(File.join(session_dir, INPUT_DIR, "*.json.processing"))

    # Whether a claimed input file carries +id+.
    def self.claimed_input?(session_dir, id)
      claimed_input_files(session_dir).any? do |file|
        data = JSON.parse(File.read(file))
        data.is_a?(Hash) && data["enqueued_id"] == id
      rescue JSON::ParserError, SystemCallError
        false
      end
    end

    def self.mark_removed(session_dir, id)
      return unless ENQUEUED_ID_NAME.match?(id)

      dir = File.join(session_dir, INPUT_DIR, REMOVED_DIR)
      FileUtils.mkdir_p(dir)
      AtomicFile.write(File.join(dir, id), "")
    rescue SystemCallError => e
      Log.warn(:bridge, "removed_tombstone_write_failed", error: e.class.name, msg: e.message)
    end
    private_class_method :mark_removed

    def self.unmark_removed(session_dir, id)
      FileUtils.rm_f(File.join(session_dir, INPUT_DIR, REMOVED_DIR, id)) if ENQUEUED_ID_NAME.match?(id)
    end
    private_class_method :unmark_removed

    # How old a per-input tombstone (input/removed/, TurnCheckpoint's
    # input/settled/) gets before a worker's start prunes it (#prune_old).
    # A wait reads one at its next poll (ReplyWait::POLL_INTERVAL) and a
    # later `chi send --wait --turn` reads a settled one at its start, so
    # only a wait whose process slept (a closed laptop) or one started long
    # after needs it to stay. A removed one gone under a live wait would
    # read as a merge (the wrong reply), so the age is generous: a week,
    # half the session retention (14 days), for one small file per
    # file-delivered command or dequeue.
    TOMBSTONE_MAX_AGE = 7 * 24 * 3600

    # Deletes the files in input/<+subdir+> last written more than
    # +max_age+ seconds ago; one that can't be read or deleted stays.
    # @return [Integer] how many went
    def self.prune_old(session_dir, subdir, max_age: TOMBSTONE_MAX_AGE)
      cutoff = Time.now - max_age
      Dir.glob(File.join(session_dir, INPUT_DIR, subdir, "*")).count do |file|
        next false unless File.mtime(file) < cutoff

        File.delete(file)
        true
      rescue SystemCallError
        false
      end
    end

    # The removed tombstones past +max_age+ (#prune_old).
    def self.prune_removed(session_dir, max_age: TOMBSTONE_MAX_AGE) = prune_old(session_dir, REMOVED_DIR, max_age: max_age)

    # @return [Boolean] whether the queued input +enqueued_id+ was removed
    #   before it ran (#take_queued_input's tombstone), or is being removed:
    #   the tombstone goes first, so while its claimed file is still there
    #   (#claimed_input?) the removal may yet lose to a turn's claim
    def self.removed?(session_dir, enqueued_id)
      id = enqueued_id.to_s
      ENQUEUED_ID_NAME.match?(id) && File.exist?(File.join(session_dir, INPUT_DIR, REMOVED_DIR, id))
    end
  end
end
