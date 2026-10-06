# frozen_string_literal: true

require_relative "../client_id"
require_relative "../session"
require_relative "../bridge_client"
require_relative "../bridge/turn_accumulator"
require_relative "../tools/delegate"

module Samagotchi
  # Loaded on first use: session_manager requires terminal_ui, which
  # requires the Engine and so the plugins (a require cycle otherwise).
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)

  module Plugin
    # ctx.sessions (docs/plugins.md, Sessions): other sessions, from a
    # plugin. A fork is an ordinary chi session in its own worker, shown in
    # every list as a child of this one (↳ parent).
    class Sessions
      # A fork, send or read that couldn't be done; the message says why.
      class Error < StandardError; end

      # @param host [Host] session_id, cwd, model_name and state_dir
      def initialize(host)
        @host = host
      end

      # Start a child session from +messages+ (usually ctx.messages plus
      # more). With no prompt the child waits idle for the user; with one it
      # runs it as its first turn, and counts against session.max_children.
      # Each image a message names is copied into the child, or dropped with
      # a note in its message when its file is gone.
      # @param messages [Array<Hash>] the child's conversation to start with
      # @param title [String, nil] what the lists show for it (the prompt, or
      #   the first user message, by default)
      # @param prompt [String, nil] the child's first turn
      # @return [String] the child's id
      # @raise [Error] no session yet, a scratch session (the child would
      #   outlive it), or too many children running
      def fork(messages:, title: nil, prompt: nil)
        parent_id = @host.session_id.call or raise Error, "this session has no id yet"
        raise Error, "a scratch session starts no other sessions: they would outlive it" if @host.scratch&.call

        state_dir = self.state_dir
        prompt = prompt.to_s.strip.empty? ? nil : prompt.to_s
        check_children(parent_id, state_dir) if prompt

        child = SessionManager.spawn_session(
          prompt: prompt, working_directory: @host.cwd.call || Dir.pwd, model_name: @host.model_name&.call,
          parent_id: parent_id, messages: Array(messages).map { |message| unfrozen(message) }, title: title,
          images_from: Session.session_dir(parent_id, state_dir: state_dir), state_dir: state_dir
        )
        child.id
      end

      # Send +text+ to session +id+ as a user message (it runs as a turn;
      # a stopped session is woken). Waits up to 5 s for its worker, so call
      # it from an anytime command or your own thread, never a tool or hook
      # of a running turn.
      # @return [String] the id of the session it went to
      # @raise [Error] no such session, a REPL owns it, or it wasn't taken
      def send(id, text)
        raise Error, "nothing to send" if text.to_s.strip.empty?

        state_dir = self.state_dir
        sid = resolve(id, state_dir)
        delivered = SessionManager.deliver_turn(sid, prompt: text.to_s, client_id: ClientId::PLUGIN, state_dir: state_dir)
        case delivered[:status]
        when :accepted then sid
        when :refused then raise Error, "session #{sid[0, 8]} refused the message (#{delivered.dig(:ack, "error")})"
        when :timeout then raise Error, "session #{sid[0, 8]}'s worker did not answer in time; the message was not sent"
        else raise Error, "the message to session #{sid[0, 8]} could not be written"
        end
      rescue SessionManager::OwnedByTUI
        raise Error, "session #{sid[0, 8]} is open in a chi REPL, which takes no messages from others"
      end

      # Session +id+ now: from its worker when one runs (with a running turn
      # so far), else as saved.
      # @return [Hash] {id:, title:, status:, parent_id:, running:, messages:}
      #   (messages without the system prompt, symbol keys)
      # @raise [Error] no such session
      def read(id)
        state_dir = self.state_dir
        sid = resolve(id, state_dir)
        session = Session.load(sid, state_dir: state_dir)
        messages = session.messages
        running = false
        if (live = live_snapshot(sid, state_dir))
          messages = Array(live["messages"]).map { |message| symbolize_message(message) }
          if (turn = live["current_turn"])
            running = true
            messages += Bridge::TurnAccumulator.messages_of(deep_symbolize(turn))
          end
        end
        { id: sid, title: session.first_preview.to_s, status: session.status.to_s, parent_id: session.parent_id,
          running: running, messages: without_system_head(messages) }
      end

      private

      def state_dir = @host.state_dir&.call || Session.default_state_dir

      def resolve(id, state_dir)
        sid = Session.resolve_id(id.to_s.strip, state_dir: state_dir)
        raise Error, "no session #{id}" unless sid && Session.exist?(sid, state_dir: state_dir)

        sid
      rescue Session::AmbiguousId, ArgumentError => e
        raise Error, e.message
      end

      def check_children(parent_id, state_dir)
        running = Tools::Delegate.running_children(parent_id, state_dir: state_dir)
        max = Tools::Delegate.max_children
        return if running.size < max

        raise Error, "#{running.size} child sessions of this session are running (the most is #{max}, " \
                     "#{Tools::Delegate::MAX_CHILDREN_KEY}): #{running.map { |s| s[:short_id] }.join(", ")}"
      end

      def live_snapshot(sid, state_dir)
        BridgeClient.discover(sid, session_dir: Session.session_dir(sid, state_dir: state_dir))&.get_json("snapshot")
      rescue StandardError
        nil
      end

      def without_system_head(messages)
        first = messages.first
        system = first && first[:role].to_s == "system" && first[:kind].to_s.empty?
        system ? messages.drop(1) : messages
      end

      # A message a plugin got frozen (ctx.messages), as a session holds it.
      def unfrozen(message)
        message.to_h { |key, value| [key.to_sym, value.frozen? && value.is_a?(String) ? value.dup : value] }
      end

      # Symbol keys, as Session.load gives them (its image refs too).
      def symbolize_message(message)
        message = message.transform_keys(&:to_sym)
        message[:images] = message[:images].map { |ref| ref.transform_keys(&:to_sym) } if message[:images].is_a?(Array)
        message
      end

      def deep_symbolize(value)
        case value
        when Hash then value.to_h { |k, v| [k.to_sym, deep_symbolize(v)] }
        when Array then value.map { |v| deep_symbolize(v) }
        else value
        end
      end
    end
  end
end
