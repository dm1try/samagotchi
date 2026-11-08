# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "securerandom"
require "rbconfig"
# Everything the parts (session_manager/*.rb, required at the end) need loads
# here, before the class opens: a file declaring `autoload :SessionManager`
# (child_move, reply_wait, ...) loaded after that point, while
# SessionManager autoloads, drops the half-built class, and the parts then
# build another without the facade's methods (spec/require_cycle_spec.rb).
# Parts require only the leaves their class bodies read (none autoloads
# SessionManager: spec/require_cycle_spec.rb).
require_relative "chi_home"
require_relative "system_one/runs"
require_relative "child_env"
require_relative "client_id"
require_relative "analytics_file"
require_relative "atomic_file"
require_relative "config"
require_relative "delivery"
require_relative "steer"
require_relative "participant_messages"

require_relative "session"
require_relative "session_inbox"
require_relative "session_metrics"
require_relative "effective_model"
require_relative "session_setup"
require_relative "host_registry"
require_relative "utf8_default"
require_relative "turn_note"
require_relative "owner_lock"
require_relative "process_group"
require_relative "bridge_client"
require_relative "worker_sidecar"
require_relative "worker_link"
require_relative "worker_idle_exit"
require_relative "worker_signals"
require_relative "chi_invocation"
require_relative "log"
require_relative "degrade"
require_relative "log_path"
require_relative "paths"
require_relative "project_env"
require_relative "model_profile"
require_relative "installed_gem"
require_relative "installed_versions"
require_relative "recap_store"
require_relative "reminder_carry"
require_relative "archive_store"
require_relative "continue_offer"
require_relative "image_store"
require_relative "plugin_session_state"
require_relative "context_sources"
require_relative "context_candidates_log"
require_relative "session_chain"
require_relative "child_move"
require_relative "starting_marker"
require_relative "tools/task_runtime"

module Samagotchi
  # SessionManager coordinates background session processes.
  #
  # Each session runs in its own forked Ruby process, communicating via
  # file-based IPC in the session directory.
  #
  # The session itself (messages + metadata) is always saved by Session at
  # <sessions dir>/<session_id>.json, for foreground chats too. A sibling
  # directory holds the owner lock (any owner, TUI included) and, for
  # background workers, their IPC files (input/, notes/ and output/ are
  # SessionInbox's):
  #   ~/.local/state/samagotchi/sessions/
  #   ├── <session_id>.json       # the session (Session#save)
  #   └── <session_id>/
  #       ├── owner.lock          # flock held by the session's one owner (OwnerLock)
  #       ├── input/              # clients (web/terminal UI) write messages here
  #       │   └── <timestamp>.json # one file per user message: {prompt, client_id,
  #       │                        # enqueued_id, no_interrupt?, images?}
  #       ├── notes/              # context notes: background text the worker adds to
  #       │   └── <ts>-<rand>.json # the conversation between turns, never a turn
  #       │                        # ({text, source, from_session?, from_cwd?, created_at, objectives?})
  #       ├── output/             # agent writes responses here
  #       │   └── <timestamp>.txt # one file per agent response
  #       └── bridge.json         # Bridge sidecar (how clients reach the worker)
  # session_retention requires this file.
  autoload :SessionRetention, File.expand_path("session_retention", __dir__)
  # session_continue requires this file.
  autoload :SessionContinue, File.expand_path("session_continue", __dir__)
  # Needed only on an archive or a delete (it loads Grants).
  autoload :Participants, File.expand_path("participants", __dir__)

  # Its methods live in parts, each a module this class extends (required
  # at the end of this file; each loads alone, but is meant to be loaded
  # through this file):
  #   session_manager/spawn.rb           SpawnPart: start a session's worker, the spawns remembered
  #   session_manager/worker_command.rb  WorkerCommandPart: the worker process (CROSS-VERSION CONTRACT)
  #   session_manager/listing.rb         ListingPart: the session lists and summary rows, children, replies
  #   session_manager/delivery.rb        DeliveryPart: a user message into a session (Bridge or input file)
  #   session_manager/lifecycle.rb       LifecyclePart: stop and restart a worker
  #   session_manager/removal.rb         RemovalPart: archive, unarchive, delete
  #   session_manager/emptiness.rb       EmptinessPart: is a session empty, is a left one deleted
  class SessionManager
    # Raised when a terminal's own chi owns the session (OwnerLock kind
    # "tui": a -p --non-interactive one-shot, TerminalUI): it runs its own
    # Engine and reads no input files, so a worker must not be spawned or
    # signalled.
    class OwnedByTUI < StandardError
      # @return [String] the session it owns (a delegate's, when an archive
      #   met one)
      attr_reader :session_id

      def initialize(session_id, words = nil)
        @session_id = session_id
        super(words || "session #{session_id} is #{OwnerLock::TUI_BUSY}; let it finish first")
      end
    end

    # A `chi scratch` session: its terminal's alone (Session::SCRATCH_REFUSED).
    # An OwnedByTUI, so every caller that refuses a terminal's session
    # (chi send, chi web's 409 owned_by_tui) refuses it the same way.
    class ScratchSession < OwnedByTUI
      def initialize(session_id) = super(session_id, Session::SCRATCH_REFUSED)
    end

    # The session's live owner: the OwnerLock holder. The pid file workers
    # once wrote is never read: a stale one whose pid the OS reused would
    # make a session look owned.
    # @return [OwnerLock::Owner, nil]
    def self.session_owner(session_id, state_dir: nil)
      OwnerLock.owner(Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir))
    end

    # The session's owner (#session_owner), unless it is the interactive
    # TUI, which nothing else may resume, stop or delete.
    # @return [OwnerLock::Owner, nil]
    # @raise [OwnedByTUI]
    def self.refuse_tui!(session_id, state_dir: nil)
      owner = session_owner(session_id, state_dir: state_dir)
      raise OwnedByTUI, session_id if owner&.tui?

      owner
    end
  end
end

require_relative "session_manager/spawn"
require_relative "session_manager/worker_command"
require_relative "session_manager/listing"
require_relative "session_manager/delivery"
require_relative "session_manager/lifecycle"
require_relative "session_manager/removal"
require_relative "session_manager/emptiness"
