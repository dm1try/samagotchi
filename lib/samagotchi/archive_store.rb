# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "atomic_file"

require_relative "session"

module Samagotchi
  # A session's archive marker, <session dir>/archived (JSON):
  #   {"archived_at": t}    archived: hidden from every list, kept by the
  #                         retention sweep, not counted in its max_count
  #   {"unarchived_at": t}  archived once, then unarchived: the sweep ages
  #                         the session from max(updated_at, unarchived_at)
  # A separate file, not a session.json field: Session#save rewrites that
  # file from memory (and bumps updated_at) at every turn.
  module ArchiveStore
    FILE = "archived"

    # @return [Hash, nil] the marker (string keys), nil when none or unreadable
    def self.read(session_dir)
      data = JSON.parse(File.read(File.join(session_dir, FILE)))
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end

    def self.archived?(session_dir)
      read(session_dir)&.key?("archived_at") == true
    end

    # @return [Time, nil] when the session was last unarchived
    def self.unarchived_at(session_dir)
      value = read(session_dir)&.fetch("unarchived_at", nil)
      value && Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # @return [Boolean] whether the marker was written (false: the session
    #   file is gone, so its dir is never recreated)
    def self.archive(session_id, state_dir:)
      write(session_id, { "archived_at" => Time.now.iso8601(3) }, state_dir: state_dir)
    end

    # @return [Boolean] whether it was archived (and is not now)
    def self.unarchive(session_id, state_dir:)
      return false unless archived?(Session.session_dir(session_id, state_dir: state_dir))

      write(session_id, { "unarchived_at" => Time.now.iso8601(3) }, state_dir: state_dir)
    end

    # A human's input (ClientId.human?) came into the session: it is back in the lists. Its
    # children stay archived. Never raises.
    # @return [Boolean] whether it was archived
    def self.user_input(session_id, state_dir:)
      return false if session_id.nil?

      unarchive(session_id, state_dir: state_dir)
    rescue StandardError
      false
    end

    def self.write(session_id, record, state_dir:)
      return false unless File.exist?(Session.session_file(session_id, state_dir: state_dir))

      dir = Session.session_dir(session_id, state_dir: state_dir)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, FILE)
      AtomicFile.write(path, JSON.generate(record))
      true
    end
    private_class_method :write
  end
end
