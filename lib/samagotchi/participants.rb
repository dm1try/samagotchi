# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "atomic_file"
require_relative "participant_messages"
require_relative "archive_store"
require_relative "session"
require_relative "grants"

module Samagotchi
  # A session's participants: the people (or agents) its owner invited to
  # review it (`chi share`, the owner's participants routes), each through a
  # Grants grant. Two files in the session dir, neither in the session
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
    # What a participant is told when they try what only the owner may do:
    # a route (chi web's 403 not_permitted), a command or a shell line.
    NOT_PERMITTED = ParticipantMessages::NOT_PERMITTED

    # One participant as the sidecar has them. +removed_at+ when the grant
    # was revoked (nil while it works, or once it simply expired:
    # +expires_at+ says when). +cap+: their spending cap in dollars (the
    # worker's check before their queued turn starts), nil in a sidecar
    # from before caps.
    # +mode+: "pair" (Grant#mode); nil for an older chi's read-only
    # participant, who is not active (their turns are refused).
    Entry = Data.define(:id, :kind, :name, :role, :added_at, :expires_at, :removed_at, :cap, :mode) do
      def self.from_h(hash) = new(**members.to_h { |key| [key, hash[key.to_s]] })

      # Still invited at +now+: not removed, not expired, and invited by
      # this chi (an older chi's read-only invite has no "pair": #outdated?).
      def active?(now) = current?(now) && !outdated?

      # Not removed and not expired at +now+, whoever invited them.
      def current?(now)
        removed_at.nil? && Time.iso8601(expires_at.to_s) > now
      rescue ArgumentError
        false
      end

      # An older chi's invite for read-only turns (no "pair" mode), which
      # this chi doesn't run.
      def outdated? = mode.to_s != Grants::PAIR_MODE
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

    # The sidecar rewritten from +grants+ (that session's Grants::Grant
    # list). Nothing is written for a session without grants, nor for one
    # whose dir is gone.
    def write(session_id, grants, state_dir: Session.default_state_dir)
      return if grants.empty?

      dir = Session.session_dir(session_id, state_dir: state_dir)
      return unless File.directory?(dir)

      entries = grants.map do |grant|
        { "id" => grant.id, "kind" => grant.kind, "name" => grant.name, "role" => grant.role,
          "added_at" => grant.created_at, "expires_at" => grant.expires_at, "removed_at" => grant.revoked_at,
          "cap" => grant.spend_cap, **(grant.mode ? { "mode" => grant.mode } : {}) }
      end
      AtomicFile.write(File.join(dir, FILE), "#{JSON.pretty_generate({ "participants" => entries })}\n", perm: 0o600)
    end

    # Grants' on_write for a change to +session_ids+ (nil: the sessions
    # of the grants it changed, a revoke's result): their sidecars rewritten
    # from the grants just written, under the store's lock (two writers, chi
    # web and chi share, can't finish out of order and lose a revoke here).
    def sidecar_writer(state_dir, session_ids = nil)
      lambda do |all, result|
        (session_ids || result.map(&:session_id).uniq).each { |sid| write(sid, all.select { |grant| grant.session_id == sid }, state_dir: state_dir) }
      end
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
    # Grants), the sidecar and the audit line. A grant bound to
    # +identity+ needs +public_url+ (the chi web's Web::PublicUrl) with an
    # identity header: only a request through that proxy can carry it.
    # @return [Grants::Issued]
    # @raise [Grants::Invalid] an archived session, or bad values
    #   (Unbindable: an identity without such a public_url)
    # @raise [Session::NotFound] no such session
    def invite(grants, session_id:, name:, kind: "human", ttl: nil, cap: nil, identity: nil, public_url: nil,
               state_dir: Session.default_state_dir)
      raise Session::NotFound, session_id unless File.exist?(Session.session_file(session_id, state_dir: state_dir))

      identity = Grants.clean_identity(identity) unless identity.nil?
      raise Grants::Unbindable if !identity.nil? && public_url&.identity_header.nil?
      if ArchiveStore.archived?(Session.session_dir(session_id, state_dir: state_dir))
        raise Grants::Invalid, "session #{session_id[0, 8]} is archived: unarchive it to invite anyone"
      end

      issued = grants.issue(session_id: session_id, name: name, kind: kind, ttl: ttl, cap: cap, identity: identity,
                            on_write: sidecar_writer(state_dir, [session_id]))
      grant = issued.grant
      log(session_id, :issued, state_dir: state_dir, participant: grant.id, name: grant.name, kind: grant.kind,
                               role: grant.role, expires_at: grant.expires_at, cap: grant.spend_cap,
                               **(grant.identity ? { identity: grant.identity } : {}), mode: grant.mode)
      issued
    end

    # Sets participant +id+'s cap on +session_id+ (chi share cap): the
    # grant, the sidecar (the worker's check) and the audit line.
    # @return [Grants::Grant, nil] nil when +id+ isn't an active grant there
    # @raise [Grants::Invalid] a cap out of range
    def set_cap(grants, session_id:, id:, cap:, state_dir: Session.default_state_dir)
      grant = grants.set_cap(id, cap, session_id: session_id, on_write: sidecar_writer(state_dir, [session_id]))
      return nil unless grant

      log(session_id, :cap, state_dir: state_dir, participant: grant.id, cap: grant.spend_cap)
      grant
    end

    # The refusal for a cap change of +id+, no active participant of
    # +session_id+.
    def no_participant(id, session_id) = "no active participant #{id} in #{session_id.to_s[0, 8]} (chi share ls lists them)"

    # Revokes grants (Grants#revoke's arguments) and brings each
    # affected session's sidecar and audit trail along.
    # @return [Array<Grants::Grant>] the grants it revoked
    def revoke(grants, session_id: nil, id: nil, by: "owner", state_dir: Session.default_state_dir)
      revoked = grants.revoke(session_id: session_id, id: id, by: by, on_write: sidecar_writer(state_dir))
      revoked.group_by(&:session_id).each do |sid, ended|
        ended.each { |grant| log(sid, :revoked, state_dir: state_dir, participant: grant.id, by: by) }
      end
      revoked
    end

    # Ends the grants of sessions that were archived or deleted
    # (SessionManager): +by+ "archive" or "delete". Nothing is written for a
    # session nobody was invited to.
    # A grants store that doesn't read (Grants::Corrupt) doesn't stop
    # the archive or delete: its links already find no grant, and the
    # store itself says so (Log.warn) until it's fixed. Nor does one a newer
    # chi wrote (Newer): chi web's gate refuses a grant whose session is
    # archived or gone even when it can't write the revoke.
    def end_sessions(session_ids, by:, state_dir: Session.default_state_dir)
      grants = Grants.new(Grants.path(state_dir: state_dir))
      session_ids.each { |sid| revoke(grants, session_id: sid, by: by, state_dir: state_dir) }
    rescue Grants::Unwritable
      nil
    end
  end
end
