# frozen_string_literal: true

require "fileutils"
require_relative "../log"
require_relative "../guardrails/context"

module Samagotchi
  module Plugin
    # The Engine's side of a Context: callables, so the Engine itself is
    # never handed out. +messages+ returns the conversation, +notify+ takes
    # (text, level, label), +ask_user+ takes (question:, options:, header:,
    # allow_freeform:, hook:) like the hook runtime's, +card+ takes
    # Engine#show_card's keywords and returns the id.
    Host = Struct.new(:session_id, :cwd, :messages, :notify, :ask_user, :cancelled, :card, keyword_init: true)

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
