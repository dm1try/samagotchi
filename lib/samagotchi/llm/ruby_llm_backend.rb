# frozen_string_literal: true

require_relative "model_result"
require_relative "../client"

require "ruby_llm"

module Samagotchi
  module LLM
    # Provider backend that talks to a ruby_llm gem (OpenAI-compatible endpoint).
    #
    # Stateless, by design: every `complete` builds a FRESH RubyLLM::Chat from the
    # passed `messages:`, runs a single-pass text completion over the gem's
    # `Chat#complete` streaming path, then serializes the resulting `chat.messages`
    # back to `[{role, content}]` hashes the engine owns. No gem `Chat` is held
    # between calls, so `session.messages` is the single source of truth (this
    # mirrors NativeInContextBackend's per-turn reseed and fixes the
    # "dual source of truth" reviewer gap).
    #
    # Cancellation: the gem exposes NO cancel API, so a peer
    # `Samagotchi::Client::CancellationController` listener raises
    # `Samagotchi::Client::RequestCancelled` into the dedicated request thread
    # while it is blocked in a Faraday socket read (the sole lever the gem allows,
    # adapted from `Client#complete`'s listener). On the main thread we cannot
    # `Thread#raise` into it, so we run inline and let completion finish (graceful
    # degradation — no crash).
    class RubyLLMBackend < ModelBackend
      # The engine stores roles as STRINGS ("model", "user", ...); the gem only
      # accepts its own symbols (:assistant, :user, ...). Normalize to a symbol
      # FIRST, then map, so a `case :model` vs `"model"` mix-up can never silently
      # drop a turn — the gem's `ensure_valid_role` would raise InvalidRoleError.
      #
      # NOTE: :model and :tool_response never actually appear in
      # session.messages (only as prompt delimiters); the branches are defensive.
      INBOUND_ROLE_MAP = {
        model: :assistant,
        tool_response: :tool,
        system: :system,
        user: :user
      }.freeze

      # Emitted as STRING role keys so the round-trip matches the engine exactly.
      OUTBOUND_ROLE_MAP = {
        assistant: "model",
        tool: "tool_response",
        system: "system",
        user: "user"
      }.freeze

      def initialize(model_name:, gem_provider: :openai, assume_model_exists: true)
        @model_name = model_name
        @gem_provider = gem_provider
        @assume_model_exists = assume_model_exists
      end

      def complete(messages:, max_iterations: 100, on_stream_event: nil, cancel_controller: nil,
                   model_name: nil, max_tool_output_chars: nil)
        # Fast path: a pre-set cancel means nothing ran, so the conversation is
        # simply the inbound messages unchanged (nothing was appended).
        if cancel_controller&.cancelled?
          return Samagotchi::LLM::ModelResult.new(
            text: "", tool_calls: nil, provider: :ruby_llm,
            conversation: Array(messages), canceled: true,
            cancellation_reason: cancel_controller.reason
          )
        end

        chat = RubyLLM.chat(
          model: model_name || @model_name,
          provider: @gem_provider,
          assume_model_exists: @assume_model_exists
        )
        seed_chat(chat, messages)

        # Holder for the dedicated request thread so the cancel listener can
        # raise into it regardless of which thread triggered cancellation.
        request_thread_holder = {}
        listener_id = nil
        canceled = false
        reason = nil
        begin
          if cancel_controller
            # Registered BEFORE the request starts so an early cancel still
            # interrupts the in-flight thread (mirrors client.rb's ensure).
            listener_id = cancel_controller.on_cancel do |cancel_reason|
              target = request_thread_holder[:thread]
              target&.raise(Samagotchi::Client::RequestCancelled.new(cancel_reason))
            end
          end

          outcome = run_completion(chat, on_stream_event, request_thread_holder)
          if outcome.is_a?(Array) && outcome.first == :canceled
            canceled = true
            reason = outcome[1]
          end

          build_result(chat, response: outcome.is_a?(Array) ? outcome[1] : nil,
                             canceled: canceled, reason: reason)
        ensure
          cancel_controller&.remove_listener(listener_id) if listener_id
        end
      end

      private

      # Seed the fresh Chat from engine-format messages. No gem Chat is retained
      # on the backend (stateless by design).
      def seed_chat(chat, messages)
        gem_messages(messages).each { |attrs| chat.add_message(attrs) }
      end

      # engine {:role => "model", :content => "..."} -> gem {role: :assistant, ...}
      # Normalizes the string role to a symbol BEFORE mapping (CRITICAL — see
      # class docs).
      def gem_messages(messages)
        Array(messages).map do |entry|
          role = entry[:role].to_sym
          { role: INBOUND_ROLE_MAP.fetch(role, role), content: entry[:content] }
        end
      end

      # Runs the single-pass completion, emitting streaming events. Returns
      # [:ok, response] on success or [:canceled, reason] when the request thread
      # is interrupted with RequestCancelled.
      def run_completion(chat, on_stream_event, request_thread_holder)
        if Thread.current == Thread.main
          # Can't Thread#raise into the main thread: run inline and let the gem
          # finish (a cancel here is a no-op — graceful degradation, no crash).
          [:ok, run_off(chat, on_stream_event)]
        else
          request_thread_holder[:thread] = Thread.new do
            response = run_off(chat, on_stream_event)
            [:ok, response]
          rescue Samagotchi::Client::RequestCancelled => e
            [:canceled, e.reason]
          end
          thread = request_thread_holder[:thread]
          thread.join
          thread.value
        end
      end

      # Executes the gem's streaming completion, forwarding content chunks as
      # :generation_chunk events and one :generation_completed at the end.
      def run_off(chat, on_stream_event)
        response = chat.complete do |chunk|
          next unless chunk.respond_to?(:content)

          text = chunk.content.to_s
          next if text.empty?

          on_stream_event&.call(type: :generation_chunk, content: text, payload: nil)
        end
        length = response.respond_to?(:content) ? response.content.to_s.length : response.to_s.length
        on_stream_event&.call(type: :generation_completed, content_length: length, payload: nil)
        response
      end

      def build_result(chat, response:, canceled:, reason: nil)
        text =
          if canceled
            ""
          else
            content = response.respond_to?(:content) ? response.content : response
            content.to_s
          end

        Samagotchi::LLM::ModelResult.new(
          text: text,
          tool_calls: nil,
          provider: :ruby_llm,
          conversation: serialize_messages(chat.messages),
          canceled: canceled,
          cancellation_reason: reason
        )
      end

      # gem Message [{role: :assistant, ...}] -> engine [{role: "model", ...}]
      # (all string role keys; read plain text via msg.content).
      def serialize_messages(gem_messages)
        Array(gem_messages).map do |msg|
          role = msg.role
          content = msg.respond_to?(:content) ? msg.content.to_s : ""
          { role: OUTBOUND_ROLE_MAP.fetch(role, role.to_s), content: content }
        end
      end
    end
  end
end
