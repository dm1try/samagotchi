# frozen_string_literal: true

require "securerandom"
require "time"

require_relative "../child_reports"
require_relative "../client_id"
require_relative "../context_note"
require_relative "../log"
require_relative "../peer_mailbox"
require_relative "../peer_note"
require_relative "../peer_receipts"
require_relative "../turn_origin"
require_relative "../worker_wakes"

module Samagotchi
  class WorkerInbound
    # A mail wake turn to run: peer +peer+'s messages are in the
    # conversation, the batch's last note the start of the turn +turn_id+;
    # +plain_note+ is that note without the turn start or the wake line,
    # which #unmark_wake puts back; +agreed+: the newest message that asked
    # agrees (it counts toward session.max_wakes only).
    MailWake = Data.define(:peer, :turn_id, :plain_note, :agreed) do
      def name = "peer #{PeerMailbox.label(peer)}"
      def origin = TurnOrigin.new(client_id: "#{ClientId::PEER_PREFIX}#{peer}")
      def note = plain_note
    end

    # One message of a batch: its +peer+, the PeerMessage (nil for a
    # refused one), the note's id and +refused+ (nil, "undeclared",
    # "invalid"); +order+ sorts the batch.
    MailItem = Data.define(:peer, :message, :serial, :note_id, :refused, :order) do
      def asked = message&.wake == true
      def taken? = refused.nil?
    end

    # The fourth inbound kind: a peer's messages from the mailbox
    # (PeerMailbox), one note each, between turns. Mixed into WorkerInbound;
    # reads @session, @engine, @wakes, @awaiting_continue, @stopped,
    # @peer_registry, @peer_receipts, @mail_cap. See docs/internals/peers.md.
    module MailPart
      # The holds a caller gives (a wake can't run now) and the receipt's
      # reason for each, beside :off and WorkerWakes#wake_hold's.
      CALLER_HOLDS = %i[queued exit leaving before_turn].freeze

      # Take what peers wrote since the last look: every <peer>/in folder,
      # whatever its link (the link gates the say only). A declared peer's
      # messages become notes (in order: by +at+, then peer, then serial;
      # within one peer serial order); an undeclared peer's are refused and
      # stay untaken; a bad file is refused and taken. Notes, the session
      # saved, then the receipts (at least once; the note ids dedupe).
      # +hold+: why a wake can't run now (CALLER_HOLDS), nil when it may: the
      # batch wakes when any message asked, +hold+ is nil and the gate is
      # open (#mail_hold); within the start grace such a batch waits,
      # untaken (#mail_wake_waiting?). Not before the first turn, unless
      # one is about to run (+hold+ :before_turn).
      # @return [MailWake, nil] the wake turn to run now
      # @raise [SystemCallError, IOError] the caller logs it
      def absorb_mail(hold: nil)
        @mail_wake_waiting = false
        return nil unless @peer_registry && @peer_receipts
        return nil unless hold == :before_turn || conversation_started?
        return nil if @stopped.call

        signature = mail_signature
        return nil if signature == @mail_signature

        items = mail_items
        replayed = recover_crashed_wake(items)
        taken = items.select(&:taken?)
        asking = taken.select(&:asked).last
        @wakes.pause! if replayed && asking
        reason = (replayed && asking ? :paused : hold) || (mail_hold(asking) if asking)
        if asking && reason.nil? && @wakes.in_grace?
          @mail_wake_waiting = true
          return nil
        end

        waking = asking && reason.nil? ? SecureRandom.uuid : nil
        plain = add_mail_notes(taken, waking, asking)
        return nil if taken.any? && !save(:mail)

        @peer_receipts.absorbed(items.map { |item| receipt_item(item) }, waking: waking, hold: reason)
        @mail_signature = signature
        mail_held(asking, reason)
        waking && MailWake.new(peer: asking.peer, turn_id: waking, plain_note: plain, agreed: agreed?(asking))
      end

      # Whether #absorb_mail left a batch that would wake untaken for the
      # start grace (the idle loop looks again when it ends).
      def mail_wake_waiting? = @mail_wake_waiting == true

      private

      # Names and mtimes of the session's mailbox folders, each pass.
      def mail_signature
        PeerMailbox.peers(@session.id, state_dir: @state_dir).map do |peer|
          dir = PeerMailbox.in_dir(@session.id, peer, state_dir: @state_dir)
          [peer, File.exist?(dir) ? File.mtime(dir).to_r : nil]
        end
      end

      # Every peer's messages past its taken, checked (PeerMessage.from_file),
      # in the batch's order.
      def mail_items
        PeerMailbox.peers(@session.id, state_dir: @state_dir).flat_map do |peer|
          declared = @peer_registry.declared?(peer)
          last = nil
          PeerMailbox.messages(@session.id, peer, since: @peer_receipts.peer(peer).taken, state_dir: @state_dir).map do |entry|
            raise IOError, "unreadable peer mail #{peer} ##{entry.serial}" if entry.is_a?(PeerMailbox::BadFile) && entry.reason == "unreadable"

            message = entry.is_a?(PeerMailbox::PeerMessage) ? entry : nil
            at = message ? Time.iso8601(message.at) : Time.at(0)
            last = at unless last && last > at
            refused = if !declared then "undeclared"
                      elsif message.nil? then "invalid"
                      end
            note_id = "peer-#{peer}-#{@peer_receipts.box_for(peer)}-#{entry.serial}" if refused.nil?
            MailItem.new(peer: peer, message: refused ? nil : message, serial: entry.serial, note_id: note_id,
                         refused: refused, order: [last, peer, entry.serial])
          end
        end.sort_by(&:order)
      end

      # Why the batch's newest asking message can't wake chi now: :off
      # (peer.turns is 0), else WorkerWakes#wake_hold's (an agreeing
      # message is held by session.max_wakes only); nil: it may.
      def mail_hold(asking)
        return :off if @wakes.peer_max.zero?

        @wakes.wake_hold(awaiting_continue: @awaiting_continue.call, peer: !agreed?(asking))
      end

      def agreed?(item) = PeerNote.agrees?(item&.message&.summary)

      # The notes, in order; the last one starts the wake turn (+waking+),
      # with the wake line of the newest message that asked (+asking+).
      # @return [Hash, nil] the turn start's plain note
      def add_mail_notes(items, waking, asking)
        plain = nil
        cap = @mail_cap&.call
        items.each_with_index do |item, index|
          full = waking && item.asked
          note = mail_note(item, cap: cap, held: !full)
          if waking && index == items.size - 1
            plain = note
            note = note.merge(text: "#{note[:text]}\n#{mail_wake_line(asking, cap)}", turn_start: true, turn_id: waking)
          end
          @engine.add_context_note(@session, note)
        end
        plain
      end

      # A message's plain note: its text up to +cap+ (+held+: up to
      # PeerNote::HELD_CHARS), else a pointer at it.
      def mail_note(item, cap:, held:)
        message = item.message
        label = PeerMailbox.label(item.peer)
        body = PeerNote.body(message.text, cap, held: held)
        box = @peer_receipts.box_for(item.peer)
        text = PeerNote.message_text(label: label, serial: item.serial, summary: message.summary, body: body,
                                     read: PeerNote.read_pointer(item.peer, item.serial, box: box))
        { note_id: item.note_id, text: text, source: PeerNote.source(label), created_at: Time.now.utc.iso8601,
          peer: PeerNote.payload(peer: item.peer, label: label, re: message.re, summary: message.summary,
                                 serial: item.serial, inline: body.key?(:text)).merge("box" => box) }
      end

      # The wake line of +asking+ (the newest message that asked): the
      # closing one when it agrees, the first-word one with no re.
      def mail_wake_line(asking, cap)
        body = PeerNote.body(asking.message.text, cap)
        agreed = agreed?(asking)
        PeerNote.message_wake_line(PeerMailbox.label(asking.peer), PeerNote.read_pointer(asking.peer, asking.serial,
                                                                                         box: @peer_receipts.box_for(asking.peer)),
                                   @wakes.peer_turns, body: body, agreed: agreed, first: !agreed && asking.message.re.nil?)
      end

      # A note of this batch already in the conversation: written and saved
      # before a crash, its receipt not. A turn start among them goes back
      # plain (#unmark_wake's way). Return whether any note was present so
      # the batch cannot wake again even when its saved notes were plain.
      def recover_crashed_wake(items)
        ids = items.filter_map(&:note_id)
        present = Array(@session.messages).select { |m| ids.include?(m[:note_id]) }
        return false if present.empty?

        marked_notes = present.select { |m| m[:turn_start] }
        return true if marked_notes.empty?

        messages = @engine.messages_checkpoint
        marked_notes.each do |marked|
          item = items.find { |i| i.note_id == marked[:note_id] }
          index = messages.index { |m| m[:note_id] == marked[:note_id] }
          messages[index] = ContextNote.message(**mail_note(item, cap: @mail_cap&.call, held: !item.asked)) if index
        end
        @engine.rollback_to(messages)
        @wakes.pause!
        Log.warn(:peer, "mail_wake_recovered", notes: marked_notes.size)
        true
      end

      def receipt_item(item) = PeerReceipts::Absorbed.new(peer: item.peer, serial: item.serial, asked: item.asked,
                                                          refused: item.refused)

      # The UIs hear once that a peer's message waits for the user's next
      # one when a wake budget held it (as #peer_held does for the context
      # path).
      def mail_held(asking, reason)
        key = { max_wakes: ChildRing::MAX_WAKES_KEY, peer_turns: WorkerWakes::PEER_TURNS_KEY }[reason]
        peer_held(PeerMailbox.label(asking.peer), key) if asking && key
      end
    end
  end
end
