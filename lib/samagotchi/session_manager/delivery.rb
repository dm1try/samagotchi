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

      # What the worker applied (a Bridge ack only): the delivery asked for,
      # or next_step for a --queue that found no turn running; nil from the
      # input file or a worker older than delivery.
      def delivery = ack["delivery"]

      # A --cut's outcome ("now", "waits", "off"), nil when nothing was cut.
      def cut = ack["cut"]

      # The steer cut-after seconds, with a cut that waits only.
      def cut_after = ack["cut_after"]
    end

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
                       author: nil, pending_limit: nil, anchors: nil, state_dir: nil, manager: self, bridge: nil)
        anchors = TurnAnchors.from(anchors)
        session_dir = Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir)
        bridge ||= lambda do
          link = WorkerLink.await(session_id, session_dir: session_dir, timeout: TURN_BRIDGE_WAIT)
          link.live? ? link.client(session_id) : nil
        end
        manager.resume_session(session_id, state_dir: state_dir)
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
            options = { prompt: prompt, client_id: client_id }
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
        enqueued_id = SecureRandom.uuid
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

        presence = delivery_presence(manager, session_id, state_dir)
        # A TUI that took the session between the resume and the write never
        # reads input files; a later worker would replay this one.
        if presence.tui_owned?
          FileUtils.rm_f(path) if path.is_a?(String)
          raise OwnedByTUI, session_id
        end
        # A worker that idle-exited since the resume never reads it either:
        # wake a new one. (The exiting worker also looks for input it left;
        # one the first resume spawned that is still starting is left be.)
        manager.resume_session(session_id, state_dir: state_dir) unless presence.owned?
        DeliverResult.new(status: :accepted, via: :file,
                          ack: { "status" => "accepted", "enqueued_id" => enqueued_id, "session_id" => session_id })
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
