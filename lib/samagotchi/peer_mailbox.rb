# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "atomic_file"
require_relative "context_sources"
require_relative "peer_receipts"
require_relative "session_paths"

module Samagotchi
  # A peer agent's side of a session: what it says to chi, one file per
  # message, and its pairing. One root, <state dir>/mailbox/, beside the
  # sessions folder and apart from it: the only folder a sandboxed peer
  # writes, so it holds nothing the worker trusts (chi's side, what the
  # worker did with each message, is PeerReceipts, in the session's own
  # folder).
  #   <session id>/<peer>/link.json        PeerLink: the pairing (chi peer pair)
  #   <session id>/<peer>/in/<serial>.json PeerMessage: one message (chi peer say)
  #   <session id>/<peer>/lock             the say's, while it picks a serial and writes
  # No head file: the next serial is max(the newest file, taken) + 1, and
  # trim removes only files at or below taken, so a number is never reused
  # and a forged file with a high serial pushes the next real one above it.
  # Every file is checked before it is trusted (PeerMessage.from_file).
  # See docs/internals/peers.md.
  module PeerMailbox
    DIR = "mailbox"
    # A worker's Bridge feature: it takes the peer mail (WorkerInbound#absorb_mail).
    # chi peer pair and say refuse a live worker without it.
    FEATURE = "peer_mail"
    IN_DIR = "in"
    LINK_FILE = "link.json"
    LOCK_FILE = "lock"
    NAME_RE = /\A[a-z][a-z0-9]{0,23}\z/
    # A message file's name: its serial, no leading zero, up to 15 digits
    # (a JavaScript number holds it whole). No gap limit: a writer of the
    # mailbox folder can plant a SERIAL_MAX file and use up a peer's
    # serials (later says raise "serials are used up"). The folder's
    # writers are trusted that far, as they can delete its files.
    FILE_RE = /\A([1-9]\d{0,14})\.json\z/
    SERIAL_MAX = (10**15) - 1
    # A message file is refused above this, before it is read: the text's
    # limit (a push's, ContextSources::TEXT_MAX_BYTES) with room for JSON's
    # escapes and the other fields.
    FILE_MAX_BYTES = (ContextSources::TEXT_MAX_BYTES * 2) + 8192
    LINK_MAX_BYTES = 8192
    # A say is refused while this many messages wait untaken.
    UNTAKEN_MAX = 200
    # Trim keeps this many taken messages (the newest).
    TAKEN_KEPT = 50

    # A name, a text or a file the mailbox can't take.
    class Invalid < ArgumentError; end

    # UNTAKEN_MAX messages wait: chi hasn't taken them.
    class Full < Invalid; end

    # A pairing: the +peer+'s name, the +address+ chi's sends go to (nil:
    # answers only), when it was made and by whom (+from+, free text).
    PeerLink = Data.define(:peer, :address, :paired_at, :from) do
      def to_h = { "peer" => peer, "address" => address, "paired_at" => paired_at, "from" => from }

      # @return [PeerLink, nil] nil for a value of the wrong shape
      def self.from_h(data)
        return nil unless data.is_a?(Hash) && data["peer"].is_a?(String) && data["paired_at"].is_a?(String)
        return nil unless [data["address"], data["from"]].all? { |value| value.nil? || value.is_a?(String) }

        new(peer: data["peer"], address: data["address"], paired_at: data["paired_at"], from: data["from"])
      end
    end

    # One message from a peer: its +serial+ (the file's name), +text+,
    # +summary+ (one line, up to 200 characters), +wake+ (it asks chi to
    # run a turn), +re+ (the send it answers, ContextSources::RE_RE) and
    # +at+ (when it was written, ISO 8601).
    PeerMessage = Data.define(:serial, :text, :summary, :wake, :re, :at) do
      def to_h = { "serial" => serial, "text" => text, "summary" => summary, "wake" => wake, "re" => re, "at" => at }

      # The message in +path+, checked before it is trusted, the same checks
      # the say makes: a regular file (no link followed), its name a serial,
      # its size under FILE_MAX_BYTES before it is read, the serial in it
      # the name's, the field types.
      # @return [PeerMessage, BadFile, nil] nil for a name that isn't a
      #   serial (never read)
      def self.from_file(path)
        match = FILE_RE.match(File.basename(path)) or return nil
        serial = Integer(match[1], 10)
        stat = File.lstat(path)
        return BadFile.new(serial: serial, reason: "not_a_file") unless stat.file?
        return BadFile.new(serial: serial, reason: "too_big") if stat.size > FILE_MAX_BYTES

        raw = File.open(path, File::RDONLY | File::NOFOLLOW) { |io| io.read(FILE_MAX_BYTES + 1) }.to_s
        return BadFile.new(serial: serial, reason: "too_big") if raw.bytesize > FILE_MAX_BYTES

        from_json(raw, serial)
      rescue SystemCallError, IOError
        serial ? BadFile.new(serial: serial, reason: "unreadable") : nil
      end

      def self.from_json(raw, serial)
        data = begin
          JSON.parse(raw.force_encoding(Encoding::UTF_8))
        rescue JSON::ParserError, EncodingError
          return BadFile.new(serial: serial, reason: "json")
        end
        return BadFile.new(serial: serial, reason: "json") unless data.is_a?(Hash)
        return BadFile.new(serial: serial, reason: "serial") unless data["serial"] == serial

        reason = field_problem(data)
        return BadFile.new(serial: serial, reason: reason) if reason

        new(serial: serial, text: data["text"], summary: data["summary"], wake: data["wake"], re: data["re"], at: data["at"])
      end

      # The first field of +data+ of the wrong type or past its limit, else nil.
      def self.field_problem(data)
        text = data["text"]
        return "text" unless text.is_a?(String) && text.valid_encoding? && !text.strip.empty? &&
                             text.bytesize <= ContextSources::TEXT_MAX_BYTES

        summary = data["summary"]
        return "summary" unless summary.nil? ||
                                (summary.is_a?(String) && summary == ContextSources.one_line(summary, ContextSources::SUMMARY_MAX_CHARS))
        return "wake" unless [true, false].include?(data["wake"])
        return "re" unless data["re"].nil? || ContextSources.send_ref(data["re"])
        return "at" unless PeerMailbox.time?(data["at"])

        nil
      end
    end

    # A message file that failed PeerMessage.from_file's checks: its
    # +serial+ (its name) and why (+reason+: not_a_file, too_big,
    # unreadable, json, serial, or the field).
    BadFile = Data.define(:serial, :reason)

    module_function

    # <state dir>/mailbox; +state_dir+ is the sessions dir (SessionPaths.default_state_dir).
    def root(state_dir: nil)
      File.join(File.dirname(state_dir || SessionPaths.default_state_dir), DIR)
    end

    # @raise [SessionPaths::InvalidId]
    def session_dir(session_id, state_dir: nil)
      File.join(root(state_dir: state_dir), SessionPaths.check_id!(session_id))
    end

    # @raise [Invalid, SessionPaths::InvalidId]
    def peer_dir(session_id, peer, state_dir: nil)
      File.join(session_dir(session_id, state_dir: state_dir), check_name!(peer))
    end

    def in_dir(session_id, peer, state_dir: nil) = File.join(peer_dir(session_id, peer, state_dir: state_dir), IN_DIR)

    # @return [String] +name+
    # @raise [Invalid]
    def check_name!(name)
      return name if valid_name?(name)

      raise Invalid, name_problem(name)
    end

    def name_problem(name) = "#{name.to_s[0, 40].inspect} isn't a peer name: a lowercase letter, then lowercase " \
                             "letters and digits, up to 24"

    def valid_name?(name) = name.is_a?(String) && name.match?(NAME_RE)

    # The peer's name as chi words it, in every process ("Claude").
    def label(name) = name.to_s.capitalize

    # @return [PeerLink, nil]
    def link(session_id, peer, state_dir: nil)
      path = File.join(peer_dir(session_id, peer, state_dir: state_dir), LINK_FILE)
      return nil unless File.file?(path) && !File.symlink?(path) && File.size(path) <= LINK_MAX_BYTES

      link = PeerLink.from_h(JSON.parse(File.read(path)))
      link if link&.peer == peer
    rescue JSON::ParserError, SystemCallError, EncodingError
      nil
    end

    # The session's pairings, by peer name.
    # @return [Array<PeerLink>]
    def links(session_id, state_dir: nil)
      peers(session_id, state_dir: state_dir).filter_map { |peer| link(session_id, peer, state_dir: state_dir) }
    end

    # Pairs +peer+ with the session: link.json written whole, the in folder made.
    # @return [PeerLink]
    def pair(session_id, peer, address:, from:, state_dir: nil, now: Time.now)
      session = session_dir(session_id, state_dir: state_dir)
      raise Invalid, "#{session_id}'s mailbox folder is a link; chi doesn't follow links there" if File.symlink?(session)

      dir = peer_dir(session_id, peer, state_dir: state_dir)
      refuse_links!(peer, dir)
      FileUtils.mkdir_p(File.join(dir, IN_DIR))
      refuse_links!(peer, dir)
      link = PeerLink.new(peer: peer, address: address&.to_s, paired_at: now.utc.iso8601, from: from&.to_s)
      AtomicFile.write(File.join(dir, LINK_FILE), "#{JSON.generate(link.to_h)}\n")
      link
    end

    # Ends the pairing: link.json only. The messages stay: the worker
    # takes those that wait whatever the link.
    # @return [Boolean] whether there was one
    def unpair(session_id, peer, state_dir: nil)
      path = File.join(peer_dir(session_id, peer, state_dir: state_dir), LINK_FILE)
      return false unless File.exist?(path) || File.symlink?(path)

      File.delete(path)
      true
    rescue Errno::ENOENT
      false
    end

    # The serials in +peer+'s in folder, by name only (nothing read), in order.
    # @return [Array<Integer>]
    # A linked peer or in folder reads as none (a link is never followed).
    def serials(session_id, peer, state_dir: nil)
      dir = in_dir(session_id, peer, state_dir: state_dir)
      return [] unless real_dir?(File.dirname(dir)) && real_dir?(dir)

      Dir.children(dir).filter_map { |name| (match = FILE_RE.match(name)) && Integer(match[1], 10) }.sort
    end

    # Writes one message from +peer+, under the peer's lock: picks the
    # serial (max(the newest file, +taken+) + 1), writes the file whole,
    # then trims (files at or below +taken+, past the newest TAKEN_KEPT).
    # +taken+ is the worker's (PeerReceipts.taken).
    # @return [PeerMessage]
    # @raise [Invalid] a bad name, an empty text or one over the limit
    # @raise [Full] UNTAKEN_MAX messages wait
    def post(session_id, peer, text:, summary:, wake:, re:, taken: 0, state_dir: nil, now: Time.now)
      dir = peer_dir(session_id, peer, state_dir: state_dir)
      text = checked_text(text)
      summary = ContextSources.one_line(summary, ContextSources::SUMMARY_MAX_CHARS)
      refuse_links!(peer, dir)
      FileUtils.mkdir_p(File.join(dir, IN_DIR))
      refuse_links!(peer, dir)
      locked(dir) do
        present = serials(session_id, peer, state_dir: state_dir)
        noted = PeerReceipts.read(session_id, state_dir: state_dir).peer(peer).receipts.count { |receipt| receipt.state == "noted" }
        if noted >= UNTAKEN_MAX || present.count { |serial| serial > taken.to_i } >= UNTAKEN_MAX
          raise Full, "chi has #{UNTAKEN_MAX} unread messages from #{peer}"
        end

        serial = [present.last.to_i, taken.to_i].max + 1
        raise Invalid, "#{peer}'s serials are used up" if serial > SERIAL_MAX

        message = PeerMessage.new(serial: serial, text: text, summary: summary, wake: wake == true,
                                  re: ContextSources.send_ref(re), at: now.utc.iso8601(3))
        body = JSON.generate(message.to_h)
        raise Invalid, "the message is #{body.bytesize} bytes written; the limit is #{FILE_MAX_BYTES}" if body.bytesize > FILE_MAX_BYTES

        AtomicFile.write(File.join(dir, IN_DIR, "#{serial}.json"), body)
        trim(dir, present, taken.to_i)
        message
      end
    end

    # The checked text: a String, not empty, within the push limit.
    def checked_text(text)
      text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      raise Invalid, "the message is empty" if text.strip.empty?
      if text.bytesize > ContextSources::TEXT_MAX_BYTES
        raise Invalid, "the message is #{text.bytesize} bytes; the limit is 1 MiB (#{ContextSources::TEXT_MAX_BYTES} bytes)"
      end

      text
    end

    # +peer+'s messages past +since+, in serial order, each checked
    # (PeerMessage.from_file): a PeerMessage or a BadFile.
    # @return [Array<PeerMessage, BadFile>]
    def messages(session_id, peer, since: 0, state_dir: nil)
      dir = in_dir(session_id, peer, state_dir: state_dir)
      serials(session_id, peer, state_dir: state_dir).select { |serial| serial > since.to_i }.filter_map do |serial|
        PeerMessage.from_file(File.join(dir, "#{serial}.json"))
      end
    end

    # @return [PeerMessage, nil] +peer+'s message +serial+, when it is there and good
    def message(session_id, peer, serial, state_dir: nil)
      serial = Integer(serial.to_s, 10, exception: false) or return nil
      return nil unless serial.between?(1, SERIAL_MAX)

      dir = peer_dir(session_id, peer, state_dir: state_dir)
      refuse_links!(peer, dir)
      read = PeerMessage.from_file(File.join(dir, IN_DIR, "#{serial}.json"))
      read.is_a?(PeerMessage) ? read : nil
    rescue Errno::ENOENT
      nil
    end

    # The peer folders of a session with a valid name, sorted.
    # @return [Array<String>]
    def peers(session_id, state_dir: nil)
      dir = session_dir(session_id, state_dir: state_dir)
      return [] unless Dir.exist?(dir)

      Dir.children(dir).select { |name| valid_name?(name) && real_dir?(File.join(dir, name)) }.sort
    end

    # A directory, not a link to one.
    def real_dir?(path)
      File.lstat(path).directory?
    rescue SystemCallError
      false
    end

    # @raise [Invalid] the peer's folder or its in folder is a link
    def refuse_links!(peer, dir)
      [File.dirname(dir), dir, File.join(dir, IN_DIR)].each do |path|
        raise Invalid, "#{peer}'s mailbox folder is a link; chi doesn't follow links there" if File.symlink?(path)
      end
    end

    # A deleted session's mailbox.
    # @return [Array<String>] the paths removed
    def remove_session(session_id, state_dir: nil)
      return [] unless SessionPaths.valid_id?(session_id.to_s)

      dir = session_dir(session_id, state_dir: state_dir)
      return [] unless Dir.exist?(dir)

      FileUtils.rm_rf(dir)
      [dir]
    rescue SystemCallError
      []
    end

    def time?(value)
      return false unless value.is_a?(String) && value.length <= 40

      Time.iso8601(value)
      true
    rescue ArgumentError
      false
    end

    # The peer's lock for the block: a say picks its serial and writes
    # under it, so two writers never take one number.
    def locked(dir)
      File.open(File.join(dir, LOCK_FILE), File::RDWR | File::CREAT | File::NOFOLLOW, 0o644) do |io|
        io.flock(File::LOCK_EX)
        yield
      end
    end

    # Removes the files at or below +taken+ but the newest TAKEN_KEPT of
    # them; an untaken message is never deleted.
    def trim(dir, present, taken)
      done = present.select { |serial| serial <= taken }
      done[0...-TAKEN_KEPT].to_a.each { |serial| FileUtils.rm_f(File.join(dir, IN_DIR, "#{serial}.json")) } if done.size > TAKEN_KEPT
    end
  end
end
