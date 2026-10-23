# frozen_string_literal: true

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

    # A session to create (chi send --new): a new one, or with +continues+
    # the next link of that session's chain (which brings its own folder,
    # LLM context, thinking, toolkit and settings: the rest is nil then).
    # +preview+ set: the session starts idle with it as its preview, and
    # +prompt+ (nil) goes in later as a turn (images, a session command).
    # +setup+ is a SessionSetup for Local, a SetupWords for Remote (the
    # flags as typed: the server checks them against its own config and
    # bundles). +client_id+ (chi send's, or chi answer's for a parent's
    # /continue yes) and +images+ (images follow) are for a Remote's server,
    # which checks the first line and the model as chi send checks them
    # here (Local checks before it creates).
    NewSession = Data.define(:prompt, :preview, :continues, :working_directory, :model_name, :setup, :client_id,
                             :images) do
      def initialize(prompt:, preview: nil, continues: nil, working_directory: nil, model_name: nil, setup: nil,
                     client_id: nil, images: false) = super
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
