# frozen_string_literal: true

require_relative "paths"

module Samagotchi
  # Where a session's files are and which ids name one: the sessions dir,
  # a session's <id>.json and <id>/ dir, and the id rule every id from
  # outside meets before it becomes a path. A leaf (Paths only), so a file
  # that needs a session's path needs no Session: Session extends it, so
  # Session.session_dir and the rest answer the same. `extend self`, not
  # module_function: Session's copies must stay public.
  module SessionPaths
    extend self # rubocop:disable Style/ModuleFunction -- module_function would make Session's copies private

    STATE_SUBDIR = File.join("samagotchi", "sessions")
    FILE_EXT = ".json"

    # An id that is not a session id: it could name a path outside the
    # sessions dir ("../x", "/etc", "a/b", a NUL), or is empty.
    class InvalidId < ArgumentError; end

    # Ids are SecureRandom.uuid; anything made of letters, digits, "-" and
    # "_" (up to 128, not starting with "-") is taken, so a UUID prefix the
    # CLI resolves passes too. This is the one check every id from outside
    # (the bridge, the web routes, chi send/note, delegate) meets before it
    # becomes a path: session_dir and the session file path refuse others.
    VALID_ID = /\A[A-Za-z0-9_][A-Za-z0-9_-]{0,127}\z/

    def valid_id?(session_id)
      session_id.is_a?(String) && VALID_ID.match?(session_id)
    end

    # @raise [InvalidId] unless valid_id?(session_id)
    def check_id!(session_id)
      return session_id if valid_id?(session_id)

      raise InvalidId, "invalid session id: #{session_id.to_s[0, 80].inspect}"
    end

    # Directory for a specific session (holds IPC files alongside session.json).
    # @raise [InvalidId] for an id that isn't one (valid_id?)
    def session_dir(session_id, state_dir: default_state_dir)
      File.join(state_dir, check_id!(session_id))
    end

    # A session's <id>.json.
    # @raise [InvalidId] for an id that isn't one (valid_id?)
    def session_file(session_id, state_dir: default_state_dir)
      File.join(state_dir, "#{check_id!(session_id)}#{FILE_EXT}")
    end

    # XDG-aware sessions directory.
    def default_state_dir(env: ENV)
      File.join(Paths.state_home(env: env), STATE_SUBDIR)
    end
  end
end
