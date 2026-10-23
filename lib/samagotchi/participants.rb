# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "atomic_file"
require_relative "archive_store"
require_relative "session"
require_relative "web/grants"

module Samagotchi
  # A session's participants: the people (or agents) its owner invited to
  # review it (`chi share`, the owner's participants routes), each through a
  # Web::Grants grant. Two files in the session dir, neither in the session
  # JSON (chi web never saves that, and a worker would overwrite a field it
  # added):
  # - participants.json, the sidecar: who is or was invited, never a token
  #   or a digest. Written by whoever changes a grant (chi web, chi share);
  #   the worker reads it (Participants.read; P3's system-prompt line). A
  #   session nobody was invited to has none, so its files stay as they were.
  # - participants.jsonl, the audit trail (0600, append-only): grants issued,
  #   revoked and expired, a participant's first use and each new peer,
  #   every route refused to them.
  # Neither is copied to a continue, a fork or a delegate. See
  # docs/internals/participants.md.
  module Participants
    FILE = "participants.json"
    LOG = "participants.jsonl"

    # One participant as the sidecar has them. +removed_at+ when the grant
    # was revoked (nil while it works, or once it simply expired:
    # +expires_at+ says when).
    Entry = Data.define(:id, :kind, :name, :role, :added_at, :expires_at, :removed_at) do
      def self.from_h(hash) = new(**members.to_h { |key| [key, hash[key.to_s]] })

      # Still in the review at +now+.
      def active?(now)
        removed_at.nil? && Time.iso8601(expires_at.to_s) > now
      rescue ArgumentError
        false
      end
    end

    module_function

    # @return [Array<Entry>] the session's participants, [] without any
    def read(session_id, state_dir: Session.default_state_dir)
      file = File.join(Session.session_dir(session_id, state_dir: state_dir), FILE)
      return [] unless File.exist?(file)

      data = JSON.parse(File.read(file))
      Array(data.is_a?(Hash) ? data["participants"] : nil).filter_map { |hash| Entry.from_h(hash) if hash.is_a?(Hash) }
    rescue JSON::ParserError, SystemCallError
      []
    end

    # The sidecar rewritten from +grants+ (that session's Web::Grants::Grant
    # list). Nothing is written for a session without grants, nor for one
    # whose dir is gone.
    def write(session_id, grants, state_dir: Session.default_state_dir)
      return if grants.empty?

      dir = Session.session_dir(session_id, state_dir: state_dir)
      return unless File.directory?(dir)

      entries = grants.map do |grant|
        { "id" => grant.id, "kind" => grant.kind, "name" => grant.name, "role" => grant.role,
          "added_at" => grant.created_at, "expires_at" => grant.expires_at, "removed_at" => grant.revoked_at }
      end
      AtomicFile.write(File.join(dir, FILE), "#{JSON.pretty_generate({ "participants" => entries })}\n", perm: 0o600)
    end

    # One audit line: {"at", "event", …fields}. Nothing for a session whose
    # dir is gone (deleted, pruned).
    def log(session_id, event, state_dir: Session.default_state_dir, at: Time.now, **fields)
      dir = Session.session_dir(session_id, state_dir: state_dir)
      return unless File.directory?(dir)

      line = JSON.generate({ "at" => at.utc.iso8601(3), "event" => event.to_s }.merge(fields.transform_keys(&:to_s)))
      File.open(File.join(dir, LOG), File::WRONLY | File::APPEND | File::CREAT, 0o600) { |io| io.write("#{line}\n") }
    end

    # Invites a participant to +session_id+: the grant (+grants+, a
    # Web::Grants), the sidecar and the audit line.
    # @return [Web::Grants::Issued]
    # @raise [Web::Grants::Invalid] an archived session, or bad values
    # @raise [ArgumentError] no such session
    def invite(grants, session_id:, name:, kind: "human", ttl: nil, state_dir: Session.default_state_dir)
      raise ArgumentError, "Session not found: #{session_id}" unless File.exist?(Session.session_file(session_id, state_dir: state_dir))
      if ArchiveStore.archived?(Session.session_dir(session_id, state_dir: state_dir))
        raise Web::Grants::Invalid, "session #{session_id[0, 8]} is archived: unarchive it to invite anyone"
      end

      issued = grants.issue(session_id: session_id, name: name, kind: kind, **{ ttl: ttl }.compact)
      write(session_id, grants.list(session_id: session_id), state_dir: state_dir)
      grant = issued.grant
      log(session_id, :issued, state_dir: state_dir, participant: grant.id, name: grant.name, kind: grant.kind,
                               role: grant.role, expires_at: grant.expires_at)
      issued
    end

    # Revokes grants (Web::Grants#revoke's arguments) and brings each
    # affected session's sidecar and audit trail along.
    # @return [Array<Web::Grants::Grant>] the grants it revoked
    def revoke(grants, session_id: nil, id: nil, by: "owner", state_dir: Session.default_state_dir)
      revoked = grants.revoke(session_id: session_id, id: id, by: by)
      revoked.group_by(&:session_id).each do |sid, ended|
        write(sid, grants.list(session_id: sid), state_dir: state_dir)
        ended.each { |grant| log(sid, :revoked, state_dir: state_dir, participant: grant.id, by: by) }
      end
      revoked
    end
  end
end
