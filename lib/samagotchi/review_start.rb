# frozen_string_literal: true

require_relative "session"
require_relative "session_review"
require_relative "session_setup"
require_relative "session_chain"
require_relative "recap_store"
require_relative "guardrails/context"
require_relative "guardrails/path_resolve"
require_relative "guardrails/review_paths"
require_relative "participant_mode"

module Samagotchi
  autoload :SessionManager, File.expand_path("session_manager", __dir__)
  autoload :SessionContinue, File.expand_path("session_continue", __dir__)

  # A review session (the shared-sessions plan's §4, D2: a review is its
  # own session): chi review FILE…, chi review --from ID, the web's Start
  # review, a plugin's ctx.sessions.review. It starts idle, with a context
  # note that names its subjects and, for a fork, brings the source's recap
  # (never its transcript), and its SessionReview on the session. A fork
  # leaves its source as it is: running, unarchived, its delegates its own
  # (a continue would archive it: the coordinator reviewing its own plan
  # keeps working). See docs/sessions.md (Review sessions).
  module ReviewStart
    # A review that can't start: one message per condition.
    class Refused < ArgumentError; end

    # One message for every file that can't be a subject: missing, a
    # folder, outside the project, a secret or chi's own (ReviewPaths).
    SUBJECT_REFUSED = "%s can't be a review subject: a subject is a file in the session's project, " \
                      "not a secret (.env, keys, credentials) nor chi's own"
    NO_SUBJECTS = "a review needs subject files, or --from a session"
    TOO_MANY = "a review takes at most %d subject files"
    MAX_SUBJECTS = 20
    # Where a review's note comes from (SessionInbox.write_note).
    NOTE_SOURCE = "review"
    # How long a fork waits for its source's live worker to write a fresh
    # recap (SessionContinue::RECAP_WAIT).
    RECAP_WAIT = 30.0

    module_function

    # The project a session in +dir+ reviews: its work tree top, or +dir+
    # outside git (as ReviewBoundary's root).
    def root_for(dir) = Guardrails::GitInfo.new.root(dir) || File.expand_path(dir)

    # +given+ as project-relative subjects: each a path relative to +dir+
    # (the session's folder) or absolute, an existing file under the
    # project that ReviewPaths would let a participant read.
    # @param given [Array<String>]
    # @param dir [String] the session's folder
    # @return [Array<String>] relative to root_for(dir), in the given order, no repeats
    # @raise [Refused]
    def check_subjects(given, dir:)
      given = Array(given).map { |path| path.to_s.strip }.reject(&:empty?)
      raise Refused, format(TOO_MANY, MAX_SUBJECTS) if given.size > MAX_SUBJECTS

      root = root_for(dir)
      check = Guardrails::ReviewPaths.new(root: root)
      given.map do |path|
        full = File.expand_path(path, dir)
        raise Refused, format(SUBJECT_REFUSED, path) unless File.file?(full) && check.refusal([full]).nil?

        relative(full, root)
      end.uniq
    end

    # A fresh review session in +dir+ for +subjects+ (as given: #subjects
    # checks them), idle.
    # @param setup [SessionSetup]
    # @return [Session] (#model_warning as spawn_session's)
    # @raise [Refused] no subjects, or one #check_subjects refuses;
    #   ModelProfile::MissingModel
    def start(subjects:, dir:, model: nil, setup: SessionSetup.new, state_dir: nil)
      dir = File.expand_path(dir)
      subjects = check_subjects(subjects, dir: dir)
      raise Refused, NO_SUBJECTS if subjects.empty?

      setup = setup.with(toolkit_origin: "chosen")
      SessionManager.spawn_session(prompt: nil, preview: preview(subjects), working_directory: dir, model_name: model,
                                   setup: setup, review: SessionReview.new(subjects: subjects),
                                   note: note(subjects: subjects), note_source: NOTE_SOURCE, state_dir: state_dir)
    end

    # A review fork of +from+ (an id, a prefix, or last:<id>): a new session
    # in its folder, on +model+ or its model (SessionContinue.model_for),
    # with its setup (SessionSetup.of), seeded with a fresh recap of it (its
    # live worker is asked first, as a continue asks) and +seed+ (more
    # context, e.g. the coordinator's handoff), idle. +from+ stays as it is.
    # @param subjects [Array<String>] as given, relative to +from+'s folder
    #   (#check_subjects checks them; may be empty)
    # @return [Session]
    # @raise [ArgumentError] no such session (Session::AmbiguousId);
    #   [Refused] its folder is gone, or a subject #check_subjects refuses;
    #   ModelProfile::MissingModel
    def fork(from:, subjects: [], model: nil, seed: nil, state_dir: nil, recap_wait: RECAP_WAIT)
      sd = state_dir || Session.default_state_dir
      source = Session.load(SessionChain.resolve(from, state_dir: sd), state_dir: sd)
      dir = source.working_directory.to_s
      raise Refused, "#{source.id[0, 8]}'s folder #{dir} is gone" unless File.directory?(dir)

      subjects = check_subjects(subjects, dir: dir)
      choice = SessionContinue.model_for(source, model)
      SessionContinue.recap_before_archive(source.id, sd, wait: recap_wait)
      recap = RecapStore.read(Session.session_dir(source.id, state_dir: sd))
      session = SessionManager.spawn_session(
        prompt: nil, preview: preview(subjects, source: source), working_directory: dir, model_name: choice.model,
        setup: SessionSetup.of(source).with(toolkit_origin: "chosen"),
        review: SessionReview.new(subjects: subjects, from: source.id),
        note: note(subjects: subjects, source: source, recap: recap, seed: seed), note_source: NOTE_SOURCE, state_dir: sd
      )
      warnings = [choice.warning, session.model_warning].compact
      session.model_warning = warnings.join("; ") unless warnings.empty?
      session
    end

    # What the lists show before its first turn.
    def preview(subjects, source: nil)
      return "review: #{subjects.join(", ")}" if source.nil?

      of = source.display_title.to_s.strip
      Session.preview_of("review of #{of.empty? ? source.id[0, 8] : of}#{" (#{subjects.join(", ")})" unless subjects.empty?}")
    end

    # The review's context note: what the session is for, its subjects,
    # and for a fork where it starts from (the source's recap) and +seed+.
    # @param recap [Hash, nil] RecapStore.read's
    # @return [String]
    def note(subjects:, source: nil, recap: nil, seed: nil)
      parts = []
      if source
        started = SessionChain.clock(source.created_at) || source.created_at
        parts << "This review session starts from #{source.id[0, 8]} (#{started}), a working session: it brings " \
                 "that session's recap, not its transcript.#{SessionChain.recap_text(recap)}"
      end
      parts << "The review's subjects (project-relative): #{subjects.join(", ")}." unless subjects.empty?
      parts << "The owner invites participants to comment. A participant's comment runs as a read-only review " \
               "turn: answer it and propose any change as text or a diff for the owner to apply."
      seed = seed.to_s.strip
      parts << seed unless seed.empty?
      parts.join("\n\n")
    end

    # What inviting a participant to +session+ now means: the grant's mode
    # (Web::Grants::PAIR_MODE only when the owner is shown PAIR_WARNING: a
    # working session whose live worker runs pair turns; nil otherwise, a
    # review participant), the mode their turns get (:pair or :review) and
    # the warning shown for it (nil for a review session). One read of the
    # live worker for all three, so the stamp is what the warning said.
    ShareTerms = Data.define(:grant_mode, :mode, :warning)

    # @param session [Session]
    # @param state_dir [String, nil] the sessions' state dir (nil: the default)
    # @return [ShareTerms]
    def share_terms(session, state_dir: nil)
      return ShareTerms.new(grant_mode: nil, mode: ParticipantMode::REVIEW, warning: nil) if session.review?

      count = session.tool_output_count
      outputs = "#{count} tool output#{"s" unless count == 1} so far"
      pair = ParticipantMode.live(session, state_dir: state_dir) == ParticipantMode::PAIR
      warning = format(pair ? PAIR_WARNING : OLDER_WORKER_WARNING, id: session.id[0, 8], outputs: outputs)
      ShareTerms.new(grant_mode: (ParticipantMode::PAIR.to_s if pair), mode: pair ? ParticipantMode::PAIR : ParticipantMode::REVIEW,
                     warning: warning)
    end

    # The warning for inviting a participant to +session+ when it isn't a
    # review session (D2: sharing a working session is allowed, with a
    # warning that says what a participant's turn does there and how many
    # tool outputs its history holds); nil for a review session
    # (#share_terms). chi share and the web's Invite show it as it is.
    # @return [String, nil]
    def share_warning(session, state_dir: nil) = share_terms(session, state_dir: state_dir).warning

    # A working session's share warning (#share_warning): a participant's
    # turns act there. chi share adds the command that starts a review
    # session (chi review --from ID), as its invocation spells it.
    PAIR_WARNING = "%<id>s is a working session: a participant's turns act in it with this session's tools " \
                   "(writes included; asks come to you) and read what its history holds (%<outputs>s). " \
                   "A review session only reads."
    # The same while its live worker predates pair turns (Delivery::PAIR_FEATURE):
    # a participant invited now gets review turns, whatever happens later.
    OLDER_WORKER_WARNING = "%<id>s is a working session, but its worker predates pair turns: a participant invited " \
                           "now only reads, and can quote what its history holds (%<outputs>s). For turns that act " \
                           "in it, restart it (chi sessions restart %<id>s) and invite them again. A review session " \
                           "only reads."

    def relative(full, root)
      real_root = Guardrails::PathResolve.real(root)
      real = Guardrails::PathResolve.real(full)
      real.delete_prefix(File.join(real_root, ""))
    end
  end
end
