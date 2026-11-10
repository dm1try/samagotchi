# frozen_string_literal: true

module Samagotchi
  class SessionManager
    # How long a turn waits for the Bridge of a worker a resume just spawned.
    TURN_BRIDGE_WAIT = 5.0

    # What #deliver_turn did with a message.
    # +status+ :accepted; :refused (the Bridge refused it, or a queue would
    # reach a worker that doesn't queue); :timeout (the Bridge took it and
    # never answered); :failed (the input file couldn't be written).
    # +via+ :bridge (the worker's Bridge answered) or :file (the input-file
    # fallback); nil when nothing went in.
    # +ack+ the Bridge's reply body, or the file's {"status", "enqueued_id",
    # "session_id"}: string keys either way, {} for none.
    # +code+ a refusal's HTTP status.
    DeliverResult = Data.define(:status, :via, :ack, :code) do
      def initialize(status:, via: nil, ack: {}, code: nil) = super(status:, via:, ack: ack || {}, code:)

      def accepted? = status == :accepted

      # Sent as an input file (no Bridge): its turn and outcome carry the
      # file's enqueued_id, which a wait follows (chi send --wait).
      def file? = via == :file

      # @return [String, nil] the id the message's turn will carry
      def enqueued_id
        id = ack["enqueued_id"].to_s
        id.empty? ? nil : id
      end

      # Whether the worker took the line as a session command (a POST /turn
      # answered with its command_id).
      def command? = !ack["command_id"].to_s.empty?

      def error = ack["error"]

      def detail = ack["detail"]

      # How a delivery that did not go in reads, as one line: the word for it
      # (refused: a worker older than queueing would steer the running turn,
      # or a remote refused it as chi send refuses it here; failed: it simply
      # did not get in) and its reason. chi send prints it, and the delegate
      # tool's follow-up says it after "Error: session <id8>".
      # @return [String]
      def refusal_text
        refused = error == Delivery::QUEUE_UNAVAILABLE["error"] || continued? ||
                  DeliverResult::REMOTE_REFUSALS.include?(error)
        "#{refused ? "refused" : "failed"}: #{detail || "could not queue it"}"
      end

      # What the worker applied (a Bridge ack only): the delivery asked for,
      # or next_step for a --queue that found no turn running; nil from the
      # input file or a worker older than delivery.
      def delivery = ack["delivery"]

      # A followed send refused: a continue took the archived link it named
      # (deliver_turn's follow:); the sender resolves the head again.
      def continued? = error == DeliverResult::CONTINUED

      # A --cut's outcome ("now", "waits", "off"), nil when nothing was cut.
      def cut = ack["cut"]

      # The steer cut-after seconds, with a cut that waits only.
      def cut_after = ack["cut_after"]
    end

    # A remote's refusals of what this machine checks before sending (a
    # parent's /continue yes, a loosening /parent-answers, images to a
    # model that can't see them): its turn route's error codes. Named on
    # DeliverResult, not inside its Data.define block, where a constant
    # would land on SessionManager.
    DeliverResult::REMOTE_REFUSALS = %w[parent_answers_refused parent_continue_refused no_vision].freeze
    # A followed send's refusal (DeliverResult#continued?), here and from a
    # remote's turn route alike.
    DeliverResult::CONTINUED = "link_continued"

    # The unclaimed input files +author+ wrote.
    PARTICIPANT_QUEUE_LOCK = "participants.lock"

    # Delivery: a user message into a session, the way a UI sends one (its
    # Bridge, else the input file). Calls SpawnPart's resume_session and the
    # facade's session_owner through +manager+ (this class by default).
    # Meant to be loaded through samagotchi/session_manager.
    module DeliveryPart
      # Write a user turn into a session's input directory via the same file IPC
      # the worker polls. Reused by the bridge's POST surface so a turn is
      # fire-and-forget and never calls run_turn across the thread/process
      # boundary. The file is JSON carrying the sender's ids.
      # @param client_id [String, nil] the sending UI
      # @param enqueued_id [String, nil] the id its ACK / :turn_enqueued carry
      # @param delivery [String, nil] the wire value: "next_step" (default),
      #   "cut" or "queue"
      # @param images [Array<Hash>] image refs ({file:, name:}) in the
      #   session's images/
      # @return [String, false] the input file's path, or false.
      def write_turn_input(session_id, prompt:, client_id: nil, enqueued_id: nil, no_interrupt: false, state_dir: nil,
                           images: [], delivery: nil, author: nil, anchors: nil)
        session_dir = Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir)
        SessionInbox.write_input(session_dir, prompt: prompt, client_id: client_id, enqueued_id: enqueued_id,
                                              no_interrupt: no_interrupt, images: images, delivery: delivery, author: author,
                                              anchors: anchors)
      end

      # Hand a user message to the session the way a UI does, for the web
      # composer and `chi send` alike: wakes the worker when none runs, posts
      # through its Bridge so every live UI sees :turn_enqueued, and falls back
      # to the input file when the Bridge is gone (a worker closing it on idle
      # exit). Race-safe against a TUI taking the session, or the worker
      # exiting, between the resume and the write.
      # @param images [Array<Hash>] refs ({file:, name:}) already in images/
      # @param delivery [String, nil] what the message asks the running turn
      #   for: "next_step" (default), "cut" or "queue"
      # @param no_interrupt [Boolean] the turn runs with the raised iteration
      #   limit (an attached TUI's --no-interrupt), through the Bridge or the
      #   file; sent only when true, so older callees see no new field
      # @param author [String, nil] who wrote it when it isn't the session's
      #   owner (Web::Principal#author: chi web stamps it, never the body);
      #   to the Bridge or the file only when given, so an owner's turn is
      #   sent and saved as before
      # @param pending_limit [Integer, nil] with +author+: how many of their
      #   turns may be running or waiting (the Bridge counts them; with no
      #   worker, their waiting files): :refused 429 too_many_turns past it
      # @param anchors [TurnAnchors, Hash, nil] a Verify turn's claim, a Revise
      #   turn's draft: each refused (409, its UNAVAILABLE) by a worker without
      #   its feature
      # @param follow [Boolean] the sender resolved +session_id+ as its
      #   chain's head (chi send: SessionAccess#head), so an archived link a
      #   continue took since is refused (:refused 409 link_continued, nothing
      #   written: #follow_guard) rather than un-archived beside its new link;
      #   the sender resolves again. Others name the id they mean (the web
      #   composer, schedules, delegates, plugins, participants).
      # @param manager [#resume_session, #write_turn_input] this class, or a
      #   stand-in (the web's specs); #session_owner is optional
      # @param bridge [#call, nil] returns the BridgeClient or nil; defaults to
      #   the session's sidecar, waiting TURN_BRIDGE_WAIT for a new worker's
      # @return [DeliverResult] :accepted (via the Bridge or a file),
      #   :refused when the Bridge refused the request (any 4xx with an
      #   error: bad images, a delivery it doesn't run) or a queue would reach
      #   a worker that doesn't queue (no file then: it would steer), :timeout
      #   when it took the request but never answered (no file then), or
      #   :failed when the input file couldn't be written
      # @raise [OwnedByTUI] a one-turn chi run owns the session
      # @raise [ArgumentError] no such session
      def deliver_turn(session_id, prompt:, client_id: nil, images: [], delivery: nil, no_interrupt: false,
                       author: nil, pending_limit: nil, anchors: nil, follow: false, state_dir: nil, manager: self,
                       bridge: nil)
        follow_guard(session_id, state_dir, follow) do
          deliver_turn_now(session_id, prompt: prompt, client_id: client_id, images: images, delivery: delivery,
                                       no_interrupt: no_interrupt, author: author, pending_limit: pending_limit,
                                       anchors: anchors, state_dir: state_dir, manager: manager, bridge: bridge)
        end
      end

      # A followed send (deliver_turn's follow:) to an archived link: refused
      # when a continue took it (a successor saved, or a continue holding its
      # lock now: its successor comes), else the delivery under a shared hold
      # of the continue lock (ContinueIntent.hold), so no continue starts
      # between this check and the input going in. Any other delivery, or
      # a link not archived, is the block alone. Head.resolve answers the
      # sender before the delivery: a continue that ends or starts in
      # between is caught here, and chi send resolves again (SendCommand#target).
      # @return [DeliverResult] the block's, or the refusal
      private def follow_guard(session_id, state_dir, follow)
        sd = state_dir || Session.default_state_dir
        return yield unless follow && Session.valid_id?(session_id) &&
                            ArchiveStore.archived?(Session.session_dir(session_id, state_dir: sd))

        ContinueIntent.hold(session_id, state_dir: sd) do |held|
          successor = SessionChain::Links.new(state_dir: sd).next_of(session_id) if held
          next yield if held && successor.nil?

          words = successor ? "being continued as #{successor[0, 8]}" : "being continued"
          DeliverResult.new(status: :refused, code: 409,
                            ack: { "error" => DeliverResult::CONTINUED, "detail" => "#{words}; send again in a moment",
                                   "session_id" => session_id, "successor_id" => successor }.compact)
        end
      end

      private def deliver_turn_now(session_id, prompt:, client_id:, images:, delivery:, no_interrupt:, author:,
                                   pending_limit:, anchors:, state_dir:, manager:, bridge:)
        anchors = TurnAnchors.from(anchors)
        session_dir = Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir)
        bridge ||= lambda do
          link = WorkerLink.await(session_id, session_dir: session_dir, timeout: TURN_BRIDGE_WAIT)
          link.live? ? link.client(session_id) : nil
        end
        # Its refusals (no session, a one-turn run's, a scratch one) are
        # resume_session's to raise, in their one wording.
        start_for_send(manager, session_id, state_dir, before: true)
        enqueued_id = SessionInbox.new_enqueued_id
        if (client = bridge.call)
          if (missing = anchors.present.find { |anchor| !worker_has?(client, anchor.class::FEATURE) })
            return DeliverResult.new(status: :refused, code: 409, ack: missing.class::UNAVAILABLE)
          end
          # A worker from before queueing (no "delivery" feature) ignores the
          # field or refuses it; either way a file would steer the running turn.
          return queue_unavailable if Delivery.queue?(delivery) && !worker_has?(client, Delivery::QUEUE_FEATURE)
          # A participant's turn only to a worker with the review boundary.
          return review_unavailable if Steer.participant_author?(author) && !worker_has?(client, Delivery::REVIEW_FEATURE)

          begin
            options = { prompt: prompt, client_id: client_id, enqueued_id: enqueued_id }
            options[:images] = images unless images.empty?
            # An old worker ignores the field: it cuts anyway (its own default).
            options[:delivery] = delivery unless Delivery.next_step?(delivery)
            options[:no_interrupt] = true if no_interrupt
            options[:author] = author if author
            options[:pending_limit] = pending_limit if author && pending_limit
            options[:anchors] = anchors unless anchors.empty?
            reply = client.post_turn(**options)
            ack = reply.json
            return DeliverResult.new(status: :accepted, via: :bridge, ack: ack) if reply.status == 202 && ack.is_a?(Hash)
            # Read after its deadline and dropped: a file would run it after all.
            return turn_timeout if ack.is_a?(Hash) && ack["error"] == "deadline_passed"
            # Any other 4xx with an error is a refusal (bad images, a delivery
            # it doesn't run, a client bug): a file would bypass it, and a
            # refused queue would steer. A 413 (a body over the Bridge's
            # limit, a big piped chi send) and a 5xx keep the file fallback
            # below, which carries the delivery (a queue too).
            if (400..499).cover?(reply.status) && reply.status != 413 && ack.is_a?(Hash) && ack["error"]
              return DeliverResult.new(status: :refused, via: :bridge, code: reply.status, ack: ack)
            end
          rescue Errno::ETIMEDOUT
            # The Bridge drops a turn it reads after the request's deadline
            # (BridgeClient#post_turn), so a worker that wakes later won't run
            # it; a file would.
            return turn_timeout
          rescue SystemCallError, IOError
            nil # the worker closed its Bridge on the way out: queue the file
          end
        end
        # A participant's file only for a worker started after it: a worker
        # still holding the session with its Bridge gone (exiting) may be an
        # older one, which would run it without the review boundary.
        # (A one-turn chi run holding it is refused as for anyone, below.)
        if Steer.participant_author?(author) && (holder = delivery_presence(manager, session_id, state_dir)).owned? &&
           !holder.tui_owned?
          return DeliverResult.new(status: :timeout, via: :file,
                                   ack: { "error" => "worker_timeout",
                                          "detail" => "the session's worker is exiting, so the message was not sent; send it again" })
        end
        input = { prompt: prompt, client_id: client_id, enqueued_id: enqueued_id, state_dir: state_dir }
        input[:images] = images unless images.empty?
        input[:delivery] = delivery unless Delivery.next_step?(delivery)
        input[:no_interrupt] = true if no_interrupt
        input[:author] = author if author
        input[:anchors] = anchors unless anchors.empty?
        path = participant_queue_lock(session_dir, author && pending_limit) do
          # No worker: the participant's waiting files are all their turns,
          # counted and written under one lock (the Bridge counts under its).
          next :too_many if author && pending_limit && pending_files(session_dir, author) >= pending_limit

          manager.write_turn_input(session_id, **input)
        end
        if path == :too_many
          return DeliverResult.new(status: :refused, code: 429,
                                   ack: { "error" => "too_many_turns", "detail" => ParticipantMessages::TOO_MANY_TURNS })
        end
        return DeliverResult.new(status: :failed) unless path

        # A TUI that took the session between the resume and the write never
        # reads input files; a later worker would replay this one.
        # A worker that idle-exited since the resume never reads it either:
        # wake a new one. (The exiting worker also looks for input it left;
        # one the first resume spawned that is still starting is left be.)
        start_for_send(manager, session_id, state_dir, before: false) do
          FileUtils.rm_f(path) if path.is_a?(String)
          raise OwnedByTUI, session_id
        end
        DeliverResult.new(status: :accepted, via: :file,
                          ack: { "status" => "accepted", "enqueued_id" => enqueued_id, "session_id" => session_id })
      end

      # deliver_turn's two liveness checks, on the session inbox's send row
      # (SessionInbox::WakePolicy: send un-stops and starts an archived
      # link). The row follows a chain, deliver_turn doesn't: it acts on
      # the id it is given, and a caller that follows (chi send) resolves
      # the head first (SessionAccess#head): resume_session unless a
      # worker holds the session or one is being started. Its refusals (no
      # session, a one-turn run's, a scratch one) are resume_session's to
      # raise, in their one wording: +before+ the write, a session it would
      # not resume is checked for them (WakePolicy#refusal: the file read
      # only then, resume_session reads it otherwise); after it, a one-turn
      # run that took the session since runs the block, and a worker that
      # is leaving (OwnerLock::Owner#leaving?: its Bridge closed, the lock
      # held for its last work) has its input served by its own respawn
      # (WorkerBoot's leave): a stop that landed before this send is
      # cleared, as resume_session clears it (a send un-stops); one that
      # lands after it still wins.
      private def start_for_send(manager, session_id, state_dir, before:)
        presence = delivery_presence(manager, session_id, state_dir)
        policy = SessionInbox::WakePolicy.for(:send)
        outcome = policy.decide(presence)
        yield if outcome == :owned && block_given?
        if !before && outcome == :live && presence.stop_marked? && presence.owner&.leaving?
          Session.clear_stopped(session_id, state_dir: state_dir || Session.default_state_dir)
          Log.info(:worker, "send_unstopped_leaving", sid: session_id[0, 8])
        end
        if %i[live starting].include?(outcome)
          return unless before

          load = -> { Session.load(session_id, state_dir: state_dir || Session.default_state_dir) }
          return unless policy.refusal(presence, load: load)
        end
        manager.resume_session(session_id, state_dir: state_dir)
      end

      # Whether the worker +client+ talks to names +feature+: the features of
      # the sidecar the client was made from (the Live link WorkerLink.await
      # found), not a second read of bridge.json.
      private def worker_has?(client, feature) = client.features.include?(feature)

      # The block under the session's participant queue lock (a file lock:
      # chi web's threads, and another chi web), when +locked+; else as is.
      private def participant_queue_lock(session_dir, locked)
        return yield unless locked

        FileUtils.mkdir_p(session_dir)
        File.open(File.join(session_dir, PARTICIPANT_QUEUE_LOCK), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      private def pending_files(session_dir, author)
        SessionInbox.find_new_input_files(session_dir).count do |file|
          data = JSON.parse(File.read(file))
          data.is_a?(Hash) && data["author"] == author
        rescue JSON::ParserError, SystemCallError
          false
        end
      end

      private def queue_unavailable
        DeliverResult.new(status: :refused, code: 409, ack: Delivery::QUEUE_UNAVAILABLE)
      end

      private def review_unavailable
        DeliverResult.new(status: :refused, code: 409, ack: Delivery::REVIEW_UNAVAILABLE)
      end

      private def turn_timeout
        DeliverResult.new(status: :timeout, via: :bridge,
                          ack: { "error" => "worker_timeout",
                                 "detail" => "the session's worker did not answer, so the message was not sent" })
      end

      # The session's WorkerPresence, its owner read through +manager+ (a
      # stand-in's #session_owner is optional: then none).
      private def delivery_presence(manager, session_id, state_dir)
        owner = Degrade.call(:worker, "owner_unreadable", sid: session_id) { manager.session_owner(session_id, state_dir: state_dir) }
        WorkerPresence.read(session_id, state_dir: state_dir, owner: owner)
      end
    end

    extend DeliveryPart
  end
end
