# frozen_string_literal: true

require "json"
require "time"
require_relative "atomic_file"
require_relative "log"

module Samagotchi
  # Which image files of a session's images/ a participant uploaded: the
  # one thing that lets a participant name an image in their turn or read
  # it back (chi web's ParticipantImages). ImageStore is content-addressed
  # and keeps no metadata, so ownership is chi web's own record, written
  # only here, never derived from a ref's source, a name or a message.
  # Keyed by (file, grant): an owner's or another grant's identical image
  # never changes hands. Also each grant's upload attempts, accepted or
  # refused (Grants::MAX_IMAGE_ATTEMPTS).
  #
  # participant_images.json in the session folder (beside participants.json,
  # not in images/, which the image route serves), written whole
  # (AtomicFile). Callers serialize read-then-write themselves (chi web's
  # @participant_images_mutex). A file that doesn't read fails closed: every
  # grant is at quota and owns nothing (Log.warn); the owner can delete it.
  # See docs/internals/participants.md.
  module ParticipantUploads
    FILE = "participant_images.json"

    # One upload: +file+ is the ref's "images/<hash>.<ext>".
    Entry = Data.define(:file, :grant_id, :at)

    # What the file holds; +broken+ when it doesn't read (then every grant
    # is at quota and at its attempts cap, and owns nothing). Read it once
    # per check and ask it (#count, #attempts, #owned?).
    State = Data.define(:entries, :attempts, :broken) do
      def count(grant_id) = broken ? Float::INFINITY : entries.count { |entry| entry.grant_id == grant_id }
      def attempts_of(grant_id) = broken ? Float::INFINITY : attempts.fetch(grant_id, 0)
      def owned?(file, grant_id) = entries.any? { |entry| entry.file == file && entry.grant_id == grant_id }
    end
    BROKEN = State.new(entries: [].freeze, attempts: {}.freeze, broken: true)

    module_function

    # @return [State]
    def read(dir)
      path = File.join(dir, FILE)
      return State.new(entries: [], attempts: {}, broken: false) unless File.exist?(path)

      data = JSON.parse(File.read(path))
      raise TypeError, "not an object" unless data.is_a?(Hash)

      entries = Array(data["images"]).map do |hash|
        Entry.new(file: hash.fetch("file").to_s, grant_id: hash.fetch("grant_id").to_s, at: hash["at"].to_s)
      end
      attempts = data["attempts"] || {}
      raise TypeError, "attempts not an object" unless attempts.is_a?(Hash)

      State.new(entries: entries, attempts: attempts.transform_values(&:to_i), broken: false)
    rescue JSON::ParserError, SystemCallError, TypeError, KeyError, NoMethodError => e
      Log.warn(:web, "participant_images_unreadable", file: path, msg: e.message)
      BROKEN
    end

    # Distinct files +grant_id+ uploaded; a broken record reads as at quota.
    def count(dir, grant_id) = read(dir).count(grant_id)

    # Uploads +grant_id+ tried, refused ones counted; a broken record reads
    # as at the cap.
    def attempts(dir, grant_id) = read(dir).attempts_of(grant_id)

    # Whether +grant_id+ uploaded +file+ ("images/<hash>.<ext>").
    def owned?(dir, file, grant_id) = read(dir).owned?(file, grant_id)

    # Records +file+ as +grant_id+'s (once: an owned file adds nothing).
    # A broken record is left as it is. +state+: the record as the caller
    # just read it (under its lock), else read here.
    # @return [Boolean] whether an entry was added
    def add(dir, file:, grant_id:, at: Time.now, state: read(dir))
      return false if state.broken
      return false if state.owned?(file, grant_id)

      write(dir, state.entries + [Entry.new(file: file, grant_id: grant_id, at: at.utc.iso8601)], state.attempts)
      true
    end

    # Counts one upload attempt of +grant_id+. A broken record is left as it
    # is. +state+ as #add's.
    def attempt!(dir, grant_id, state: read(dir))
      return if state.broken

      write(dir, state.entries, state.attempts.merge(grant_id => state.attempts.fetch(grant_id, 0) + 1))
    end

    def write(dir, entries, attempts)
      body = { "images" => entries.map { |entry| entry.to_h.transform_keys(&:to_s) }, "attempts" => attempts }
      AtomicFile.write(File.join(dir, FILE), "#{JSON.pretty_generate(body)}\n", perm: 0o600)
    end
    private_class_method :write
  end
end
