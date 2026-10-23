# frozen_string_literal: true

require_relative "participant_messages"

module Samagotchi
  # The seam between chi's session commands (chi send, answer, note,
  # session-scope context, sessions list/stop/restart/archive/unarchive/
  # delete) and where the sessions live. One object per command run:
  # Local reads and writes this machine's session files and workers; a
  # Remote (chi --remote NAME, CHI_REMOTE) does the same over another
  # machine's chi web, raising the same errors with the same words.
  # The commands keep their wording, exit codes and checks; what they ask
  # of a session goes through here. Session commands and flags that run on
  # this machine only are listed in SessionAccess::Contract. See
  # docs/architecture.md (Session access).
  module SessionAccess
    autoload :Local, File.expand_path("session_access/local", __dir__)
    autoload :Contract, File.expand_path("session_access/contract", __dir__)
    autoload :Remote, File.expand_path("session_access/remote", __dir__)
    autoload :Dispatch, File.expand_path("session_access/dispatch", __dir__)

    # A remote's chi web could not be asked, or answered what this chi can't
    # use: the message names the remote and what failed ("remote studio
    # (http://192.168.1.29:4567): connection refused"). Only a Remote raises
    # it; a command prints it as it prints its other failures (exit 1).
    class RemoteFailed < StandardError; end

    # A remote's chi web is from before the routes this command needs
    # ("remote studio runs chi 0.102.0, too old for this command through
    # --remote: update chi there (chi update)").
    class RemoteTooOld < RemoteFailed; end

    # A remote's chi web refused this machine's token (401), or answers its
    # LAN IP only (403 forbidden): Remote.access_error's words.
    class AuthRefused < RemoteFailed; end

    # The errors a participant's token meets (docs/internals/participants.md),
    # one message each, built from the remote's label ("remote studio
    # (http://…)"). chi web's code for each is its CODE.

    # 401 token_revoked: the owner revoked the grant, or archived or
    # deleted its session.
    class TokenRevoked < AuthRefused
      CODE = "token_revoked"
      def initialize(label) = super("#{label}: this review link was revoked by the session's owner")
    end

    # 401 token_expired: the grant's time ran out.
    class TokenExpired < AuthRefused
      CODE = "token_expired"
      def initialize(label) = super("#{label}: this review link expired: ask the session's owner for a new one")
    end

    # 403 not_permitted: a participant's token on a route only the session's
    # owner may use.
    class NotPermitted < RemoteFailed
      CODE = "not_permitted"
      def initialize(label) = super("#{label}: this token is a participant's: only the session's owner can do that")
    end

    # 429 too_many_turns (P3b): the participant's turns already wait in the
    # queue up to their limit.
    class TooManyTurns < RemoteFailed
      CODE = "too_many_turns"
      def initialize(label) = super("#{label}: #{ParticipantMessages::TOO_MANY_TURNS}")
    end

    # 429 cap_reached (P3b): the participant's grant spent its cap.
    class CapReached < RemoteFailed
      CODE = "cap_reached"
      def initialize(label) = super("#{label}: #{ParticipantMessages::CAP_REACHED}")
    end

    # A remote's chi web refused a request for a reason this machine checks
    # itself before sending (a parent's /continue yes, a loosening
    # /parent-answers, images to a model that can't see them): +message+
    # is the server's text, the words chi send uses on its own machine.
    # +code+ is chi web's error code.
    class Refused < StandardError
      attr_reader :code

      def initialize(message, code:)
        @code = code
        super(message)
      end
    end

    # A remote's chi web refused a request's values as a usage error would
    # on this machine (a bad --set, --toolkit or --dir there): chi send
    # exits 2 with its message.
    class BadRequest < Refused; end

    # One participant's grant as chi share ls shows it
    # (Web::Grants::Grant#public_h): never its token or digest. +state+
    # "active", "revoked" or "expired".
    # +cap+ dollars and +queue+ turns (nil from a chi web before them).
    ParticipantView = Data.define(:id, :session_id, :kind, :name, :role, :created_at, :expires_at, :revoked_at,
                                  :revoked_by, :last_used_at, :state, :cap, :queue) do
      def self.from_h(hash) = new(**members.to_h { |key| [key, hash[key] || hash[key.to_s]] })
    end

    # What chi share made: the participant, their token and the link that
    # carries it (both shown this once: chi keeps only a digest), and
    # whether that chi web listens on the LAN (+lan+ false: the link works
    # on that machine only), and the warning for sharing a working session
    # (ReviewStart.share_warning; nil for a review session).
    Invitation = Data.define(:participant, :token, :link, :lan, :warning) do
      def initialize(participant:, token:, link:, lan:, warning: nil) = super

      def inspect = "#<Invitation #{participant.id}>"
      alias_method :to_s, :inspect
    end

    # A session to create (chi send --new): a new one, or with +continues+
    # the next link of that session's chain (which brings its own folder,
    # LLM context, thinking, toolkit and settings: the rest is nil then).
    # +preview+ set: the session starts idle with it as its preview, and
    # +prompt+ (nil) goes in later as a turn (images, a session command);
    # +idle+ alone: it starts idle with no preview (a remote attach's new
    # session, whose -p goes in once attached).
    # +setup+ is a SessionSetup for Local, a SetupWords for Remote (the
    # flags as typed: the server checks them against its own config and
    # bundles). +client_id+ (chi send's, or chi answer's for a parent's
    # /continue yes) and +images+ (images follow) are for a Remote's server,
    # which checks the first line and the model as chi send checks them
    # here (Local checks before it creates). +review+ (a Review) makes it a
    # review session (chi review): idle, no prompt, and with +review.from+
    # a review fork of that session (its folder and setup: the rest is nil).
    NewSession = Data.define(:prompt, :preview, :continues, :working_directory, :model_name, :setup, :client_id,
                             :images, :idle, :review) do
      def initialize(prompt:, preview: nil, continues: nil, working_directory: nil, model_name: nil, setup: nil,
                     client_id: nil, images: false, idle: false, review: nil) = super
    end

    # A review session to create (NewSession#review): +subjects+ as typed
    # (relative to the session's folder; the side that has the files checks
    # them, ReviewStart.check_subjects), +from+ the session a review fork
    # starts from (an id, a prefix or last:<id>), or nil.
    Review = Data.define(:subjects, :from) do
      def initialize(subjects: [], from: nil) = super(subjects: Array(subjects).map(&:to_s), from: from)
    end

    # chi send --new's setup flags as typed, for a Remote: +llm_context+
    # {strategy:, apply:, budget_tokens:} words, +thinking+ and
    # +parent_answers+ level words, +toolkit+ a name, +tools+ and
    # +no_tools+ names, +settings+ {"KEY" => "VALUE"} as --set gave them.
    # The server reads each as its create route does (POST /api/sessions).
    SetupWords = Data.define(:llm_context, :thinking, :toolkit, :tools, :no_tools, :settings, :parent_answers) do
      def initialize(llm_context: nil, thinking: nil, toolkit: nil, tools: [], no_tools: [], settings: nil,
                     parent_answers: nil) = super
    end

    # A session as a session command reads it (Local: the Session itself;
    # Remote: chi web's brief read). The fields the commands use, and
    # Session's #display_title.
    # @!attribute owner [OwnerLock::Owner, nil] its worker or chi REPL
    # @!attribute pending_question [PendingQuestion, nil] the file's
    SessionView = Data.define(:id, :status, :title, :display_title, :project_root, :working_directory, :model_name,
                              :model_typed, :parent_answers, :owner, :pending_question)

    # What chi send --new created (Remote; Local gives the Session): its
    # id, a model warning, the session it continues, the delegates it took
    # over, and the server's word on a --parent-answers looser than its
    # config.yml's (capped).
    Created = Data.define(:id, :model_warning, :continues, :moved_children, :parent_answers_warning)

    # A session's worker as an attach finds it (Local#worker, chi web's GET
    # …/worker): +sidecar+ the live worker's WorkerSidecar (port, version,
    # features, epoch; nil: none runs), +stopped+ its stop marker, +owner+
    # its OwnerLock::Owner (a worker, a chi REPL, nil).
    WorkerState = Data.define(:sidecar, :stopped, :owner) do
      def live? = !sidecar.nil?

      # No Bridge, and the owner is a worker leaving (writing its recap on
      # leave): a wake waits for it (Local#wake).
      def leaving? = !live? && !!owner&.leaving?
    end

    # What a wake for an attach did (Local#wake, chi web's POST …/wake):
    # +woke+ it started the worker (false: one ran), +sidecar+ the live
    # worker's (nil: its Bridge didn't come within the wait).
    Woken = Data.define(:woke, :sidecar)

    # A remote attach's wake (Remote#attach_wake, chi web's POST …/wake):
    # +worker+ the live worker as chi web names it ({"epoch", "started_at",
    # "version", "features"}, string keys: Remote#attach_client's), and
    # what the TUI reads of that machine: its config's +default_model+,
    # the session's parent +strategy+ (Guardrails::ParentPolicy::Strategy),
    # the newest chi +installed+ there.
    WakeReply = Data.define(:woke, :worker, :default_model, :strategy, :installed)

    # A remote session's worker now (Remote#attach_worker, chi web's GET
    # …/worker): +live+, +stopped+ (its stop marker), +worker+ as in
    # WakeReply (nil: none runs), the parent +strategy+ read now, and that
    # machine's +default_model+ (nil from a chi web before it sent one).
    # +leaving+: its worker is leaving (WorkerState#leaving?), for up to
    # +leave_seconds+ more there (nil from a chi web before it sent them).
    WorkerReply = Data.define(:live, :stopped, :worker, :strategy, :default_model, :leaving, :leave_seconds) do
      def initialize(live:, stopped:, worker:, strategy:, default_model: nil, leaving: false, leave_seconds: nil) = super
    end

    # What chi send --wait and chi answer read before anything is sent, so
    # neither an older reply nor a turn that ends before the first look is
    # taken for the answer (ReplyWait's cursor:, baseline:, turn:).
    # @!attribute cursor [String, nil] the newest reply file already there
    # @!attribute baseline [ReplyWait::Baseline] the session as it was
    # @!attribute own_turn [String, nil] ReplyWait.own_turn: the turn
    #   running now, or the one whose continue offer stands
    # @!attribute known_turn [Boolean, nil] with a turn asked for
    #   (--turn), ReplyWait.known_turn?; nil without one
    # @!attribute running [Boolean] the session's status was running
    # @!attribute live [Boolean] running, or a worker or a REPL owns it
    # @!attribute settled [Boolean] idle, a turn ended and no question
    #   stands (a continue offer waits for its answer)
    # @!attribute last_turn_id [String, nil] the last ended turn's
    #   enqueued_id
    WaitStart = Data.define(:cursor, :baseline, :own_turn, :known_turn, :running, :live, :settled, :last_turn_id)

    # One attached context source as a session (or a project) sees it:
    # its Source and Snapshot (ContextSources), and for a session's list
    # whether it mutes it, a session source shadows it, and its text is
    # unread (nil for a project's, or where not asked).
    ContextEntry = Data.define(:source, :snapshot, :muted, :shadowed, :unread) do
      def initialize(source:, snapshot:, muted: nil, shadowed: nil, unread: nil) = super
    end

    # chi context push's outcome: :pushed (+before+ the revision it had,
    # +revision+ the new one), :missing (no such source) or :not_push (a
    # command source, whose text is its command's).
    ContextPush = Data.define(:status, :before, :revision) do
      def initialize(status:, before: nil, revision: nil) = super

      # Why a push to +name+ was refused as :not_push: a command source's
      # text is its command's, and a push between two fetches would read
      # as a change and then vanish.
      def self.not_push_message(name) = "#{name} runs a command, which writes its text: push goes to a --push source"
    end
  end
end
