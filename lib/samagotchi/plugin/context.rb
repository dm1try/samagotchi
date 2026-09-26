# frozen_string_literal: true

require "fileutils"
require_relative "../log"
require_relative "../guardrails/context"
require_relative "../idle_client"
require_relative "side_question"

module Samagotchi
  module Plugin
    # The Engine's side of a Context: callables, so the Engine itself is
    # never handed out. +messages+ returns the conversation, +notify+ takes
    # (text, level, label), +ask_user+ takes (question:, options:, header:,
    # allow_freeform:, hook:) like the hook runtime's, +card+ takes
    # Engine#show_card's keywords and returns the id, +ask_model+ takes
    # (chat messages, timeout:, max_tokens:, cancel_controller:) and returns
    # the answer text.
    Host = Struct.new(:session_id, :cwd, :messages, :notify, :ask_user, :cancelled, :card, :ask_model,
                      keyword_init: true)

    # ctx.ask_model failed: the model couldn't be reached, timed out, or
    # sent nothing usable. The message says why, for the user.
    class ModelError < StandardError; end

    # ctx.ask_model was cancelled (its cancel: controller).
    class ModelCancelled < ModelError; end

    # What a plugin's handlers get as +ctx+ (docs/plugins.md): the session
    # they run for, the bundle's settings and storage, a log, and the
    # user-facing helpers hooks have. One per plugin, for the Engine's life:
    # each read is of the session now.
    class Context
      # Debug-log records tagged plugins, with bundle=<bundle> (tags are a
      # closed list, LogLine::TAGS).
      class Logger
        def initialize(bundle)
          @bundle = bundle
        end

        %i[debug info warn error].each do |level|
          define_method(level) do |event, **fields|
            Samagotchi::Log.public_send(level, :plugins, event.to_s, bundle: @bundle, **fields)
          end
        end
      end

      # @return [String] the bundle the plugin came with
      attr_reader :bundle

      # @return [Hash] config.yml `bundles: <bundle>:` (string keys), frozen
      attr_reader :settings

      # @return [Logger]
      attr_reader :log

      # @param label [String] "<file> (bundle <name>)", what notices and
      #   questions are labelled by
      # @param host [Host]
      def initialize(bundle:, label:, settings:, host:, env: ENV)
        @bundle = bundle.to_s
        @label = label
        @settings = deep_freeze(settings.is_a?(Hash) ? settings : {})
        @host = host
        @env = env
        @log = Logger.new(@bundle)
        @git = Guardrails::GitInfo.new
        @data_dir = nil
      end

      # @return [String, nil] the session's id (nil before the first one)
      def session_id = @host.session_id.call

      # @return [String] the session's working directory
      def cwd = @host.cwd.call || Dir.pwd

      # @return [String, nil] the git checkout holding #cwd
      def repo_root = @git.root(cwd)

      # $XDG_STATE_HOME/samagotchi/plugins/<bundle>/, created on first use.
      # @return [String]
      def data_dir
        @data_dir ||= begin
          xdg = @env.fetch("XDG_STATE_HOME", "").to_s.strip
          base = xdg.empty? ? File.join(Dir.home, ".local", "state") : xdg
          File.join(base, "samagotchi", "plugins", @bundle).tap { |dir| FileUtils.mkdir_p(dir) }
        end
      end

      # The conversation so far, a frozen copy. While a turn runs it is the
      # conversation before that turn.
      # @return [Array<Hash>]
      def messages
        Array(@host.messages.call).map { |message| message.dup.freeze }.freeze
      end

      # One line to the user, labelled by the plugin, like a hook's
      # event[:notify]. Every UI shows it, during a turn or between turns.
      # @param level [Symbol] :info or :warn
      def notify(text, level: :info)
        @host.notify.call(text.to_s, level, @label)
        nil
      end

      # A card in every UI: a title, a body (markdown in the web, plain
      # text in the terminal) and actions, each a command line the session
      # runs when the user picks it (docs/plugins.md, Cards). Showing a card
      # with an earlier card's id replaces that card.
      # @param actions [Array<Hash>] {label:, command:} ("/hello again")
      # @param level [Symbol] :info or :warn
      # @param id [String, nil] an earlier card's id to replace it
      # @return [String] the card's id
      # @raise [ArgumentError] no title, a bad level or action
      def card(title:, body: "", actions: [], level: :info, id: nil)
        @host.card.call(source: @bundle, title: title, body: body, actions: actions, level: level, id: id)
      end

      # A side answer (plan D7): one request to the session's current model
      # on its host, with no tools and thinking off. It writes nothing,
      # fires no hooks, and doesn't touch the conversation. It blocks until
      # the answer comes, so call it from an anytime command or your own
      # thread; with a local server that runs one request at a time it
      # waits for a running turn.
      # @param messages [Array<Hash>] the conversation to ask about
      #   (usually #messages); sent as a transcript without the system
      #   prompt, tool calls, tool output and thinking; an image is a line
      #   naming it
      # @param prompt [String] the question
      # @param system [String, nil] instructions (a short default)
      # @param timeout [Numeric] seconds
      # @param max_tokens [Integer, nil] the answer's limit (default
      #   ASK_MAX_TOKENS); an answer cut off ends with "…"
      # @param cancel [CancellationController, nil] cancelling it aborts
      #   the request
      # @return [String] the answer ("" when the model said nothing)
      # @raise [ModelError] the request failed or timed out
      # @raise [ModelCancelled] +cancel+ was cancelled
      def ask_model(messages:, prompt:, system: nil, timeout: 120, max_tokens: nil, cancel: nil)
        raise ArgumentError, "ask_model needs a prompt" if prompt.to_s.strip.empty?

        request = SideQuestion.request(messages: messages, prompt: prompt, system: system)
        limit = max_tokens.nil? ? ASK_MAX_TOKENS : Integer(max_tokens)
        @host.ask_model.call(request, timeout: Float(timeout), max_tokens: limit, cancel_controller: cancel).to_s
      rescue IdleClient::SummarizeError => e
        raise ModelError, e.message
      rescue LLM::RequestCancelled
        raise ModelCancelled, "the request was cancelled"
      end

      # ctx.ask_model's answer limit when none is given.
      ASK_MAX_TOKENS = 1024

      # A single-select question through the question flow, like a hook's
      # event[:ask_user].
      # @return [Hash, nil] {selected:, freeform:, selected_indices:}, or nil
      #   (no one to ask, cancelled, bad options)
      def ask_user(question:, options:, header: nil, allow_freeform: false)
        @host.ask_user.call(question: question, options: options, header: header, allow_freeform: allow_freeform,
                            hook: @label)
      end

      # Whether the running turn was cancelled (a long tool should stop).
      def cancelled? = !!@host.cancelled.call

      private

      def deep_freeze(value)
        case value
        when Hash then value.to_h { |k, v| [deep_freeze(k), deep_freeze(v)] }.freeze
        when Array then value.map { |v| deep_freeze(v) }.freeze
        when String then value.dup.freeze
        else value
        end
      end
    end
  end
end
