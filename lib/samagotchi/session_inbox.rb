# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "securerandom"
require_relative "atomic_file"
require_relative "delivery"
require_relative "session"

module Samagotchi
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
    # @return [String, false] the input file's path, or false
    def self.write_input(session_dir, prompt:, client_id: nil, enqueued_id: nil, no_interrupt: false, images: [],
                         delivery: nil)
      images = Array(images)
      input_dir = File.join(session_dir, INPUT_DIR)
      FileUtils.mkdir_p(input_dir)

      path = File.join(input_dir, "#{Time.now.strftime("%Y%m%d%H%M%S%9N")}.json")
      record = { "prompt" => prompt.to_s, "client_id" => client_id, "enqueued_id" => enqueued_id,
                 "no_interrupt" => (no_interrupt ? true : nil),
                 "delivery" => (Delivery.queue?(delivery) ? Delivery::QUEUE : nil),
                 "images" => (images.empty? ? nil : images.map { |image| image.transform_keys(&:to_s) }) }.compact
      AtomicFile.write(path, JSON.generate(record))
      path
    rescue StandardError
      false
    end

    # Queue a context note for a session: background text its worker adds
    # to the conversation between turns. It never starts a turn.
    # @param source [String] where it came from ("cli", "slack", "session")
    # @param from_session [String, nil] the sending session, for a peer's note
    # @return [String] the note file's path
    # @raise [NoteRejected] for an empty note or one over 16 KiB (never cut)
    def self.write_note(session_id, text:, source: "cli", from_session: nil, from_cwd: nil, state_dir: nil)
      body = checked_text(text)
      sd = state_dir || Session.default_state_dir
      notes_dir = File.join(Session.session_dir(session_id, state_dir: sd), NOTES_DIR)
      FileUtils.mkdir_p(notes_dir)

      # The random part keeps two writers in one nanosecond apart; the
      # timestamp keeps the names in arrival order.
      name = "#{Time.now.strftime("%Y%m%d%H%M%S%9N")}-#{SecureRandom.hex(3)}.json"
      path = File.join(notes_dir, name)
      record = { "text" => body, "source" => source.to_s, "from_session" => from_session,
                 "from_cwd" => from_cwd, "created_at" => Time.now.iso8601 }.compact
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

    def self.write_output(session_dir, response)
      output_dir = File.join(session_dir, OUTPUT_DIR)
      FileUtils.mkdir_p(output_dir)
      timestamp = Time.now.strftime("%Y%m%d%H%M%S%9N")
      AtomicFile.write(File.join(output_dir, "#{timestamp}.txt"), response.to_s)
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

    # A claimed input file as read: its +prompt+, +origin+ ({client_id:,
    # enqueued_id:}, nil when it names no sender), whether its turn runs
    # with the raised iteration limit (+no_interrupt+, --no-interrupt), its
    # +images+ ({file:, name:} refs), and its +delivery+ ("queue" or nil; a
    # file without the key is one an older chi wrote, so nil).
    Input = Data.define(:prompt, :origin, :no_interrupt, :images, :delivery) do
      def initialize(prompt:, origin: nil, no_interrupt: false, images: [], delivery: nil) = super
    end
    # A file that doesn't parse, or isn't a JSON object: no prompt.
    UNREADABLE_INPUT = Input.new(prompt: nil)

    # @return [Input] a claimed input file's contents; UNREADABLE_INPUT for
    #   one that isn't a JSON object
    def self.read_input(claimed_file)
      data = JSON.parse(File.read(claimed_file).to_s)
      return UNREADABLE_INPUT unless data.is_a?(Hash)

      origin = { client_id: data["client_id"], enqueued_id: data["enqueued_id"] }.compact
      images = Array(data["images"]).select { |image| image.is_a?(Hash) }.map { |image| image.transform_keys(&:to_sym) }
      Input.new(prompt: data["prompt"].to_s, origin: origin.empty? ? nil : origin, no_interrupt: data["no_interrupt"] == true,
                images: images, delivery: Delivery.queue?(data["delivery"]) ? Delivery::QUEUE : nil)
    rescue JSON::ParserError
      UNREADABLE_INPUT
    end

    # Whether an unclaimed input file carries images (a mid-turn drain
    # leaves it for its own turn).
    def self.input_has_images?(input_file)
      data = JSON.parse(File.read(input_file))
      data.is_a?(Hash) && Array(data["images"]).any?
    rescue JSON::ParserError, SystemCallError
      false
    end

    # Whether a mid-turn drain leaves this unclaimed input file for a turn
    # of its own instead of merging it at a step boundary. Today that is an
    # image message (steering merges text only); the drain's file filter
    # reads this one predicate, so what a boundary refuses changes in one
    # place.
    def self.waits_for_turn_end?(input_file)
      input_has_images?(input_file)
    end

    def self.claim_input_file(input_file)
      processing_path = "#{input_file}.processing"
      File.rename(input_file, processing_path)
      processing_path
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end
  end
end
