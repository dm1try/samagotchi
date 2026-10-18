# frozen_string_literal: true

require "fileutils"
require_relative "../log"
require_relative "../paths"
require_relative "../session_metrics/cost"
require_relative "../guardrails/context"
require_relative "../idle_client"
require_relative "service"
require_relative "side_question"

module Samagotchi
  # Context#saved_session reads it; Sessions and AttachedContext load it too.
  autoload :Session, File.expand_path("../session", __dir__)

  module Plugin
    # Loaded on first ctx.sessions / ctx.context (or a bundle naming
    # Sessions::Error): they pull in the session, delivery and bridge
    # client files (~150), which a plugin that never calls them, and the
    # bundle test kit, don't need.
    autoload :Sessions, File.expand_path("sessions", __dir__)
    autoload :AttachedContext, File.expand_path("attached_context", __dir__)
    # ctx.http's file needs only json and uri (net/http loads with the first
    # real request); autoloaded so a bundle can name HttpError at load time.
    autoload :Http, File.expand_path("http", __dir__)
    autoload :HttpError, File.expand_path("http", __dir__)
    autoload :HttpCancelled, File.expand_path("http", __dir__)

    # The Engine's side of a Context: callables, so the Engine itself is
    # never handed out. +messages+ returns the conversation, +notify+ takes
    # (text, level, label, fallback_for:), +ask_user+ takes (question:, options:, header:,
    # allow_freeform:, hook:) like the hook runtime's, +card+ takes
    # Engine#show_card's keywords and returns the id, +ask_model+ takes
    # (chat messages, timeout:, max_tokens:, cancel_controller:, model:: a
    # configured model ref, nil for the session's) and returns the answer
    # text.
    # +messages_partial+ says whether +messages+ leaves out a running turn;
    # +prompt_files+ returns the files whose text the built system prompt
    # holds (SystemPrompt#prompt_files, [] before a build); +model_name+
    # (the session's resolved model ref, live after /model) and
    # +state_dir+ are what ctx.sessions forks with, and +setup+ (the
    # session's own SessionSetup), which a fork copies; +model_key+ is the
    # model's memory overlay key (ctx.model, ctx.model_key).
    # +steer+ takes (text, label), +stop_turn+ and +stop_generation+
    # (reason, label), each true when it acted on a running turn.
    # +frontend+ returns the Engine's interface (:repl, :worker,
    # :non_interactive), which ctx.frontend names for plugins.
    # +toolkit+ returns the session's toolkit name, +declared_tools+ the
    # tool names its next turn declares, +use_toolkit+ takes a name and
    # returns whether it staged it (Engine#use_toolkit).
    # +cancel_controller+ takes (handler:) and returns the controller a
    # ctx.http call without cancel: uses, nil for none: an init task's own,
    # else the running turn's for work done for it (the turn's thread, or a
    # plugin handler: +handler+) until the turn has ended.
    # +cost+ returns the session's spend now (SessionMetrics::Cost).
    Host = Struct.new(:session_id, :cwd, :messages, :messages_partial, :notify, :ask_user, :cancelled, :card,
                      :ask_model, :model_name, :model_key, :state_dir, :scratch, :setup, :prompt_files,
                      :steer, :stop_turn, :stop_generation, :frontend, :toolkit, :declared_tools, :use_toolkit,
                      :cancel_controller, :cost, keyword_init: true)

    # ctx.ask_model failed: the model couldn't be reached, timed out, or
    # sent nothing usable. The message says why, for the user.
    class ModelError < StandardError; end

    # ctx.ask_model was cancelled (its cancel: controller).
    class ModelCancelled < ModelError; end

    # What a plugin's handlers get as +ctx+ (docs/plugins.md): the session
    # they run for, the bundle's settings and storage, a log, and the
    # user-facing helpers hooks have. One per plugin, for the Engine's life:
    # each read is of the session now.
    #
    # The helpers (notify, ask_user, steer, stop_turn, stop_generation)
    # are a plugin's one surface for them. Inside one of the plugin's event
    # handlers (#with_event, on the handler's thread) they are that fire's
    # event[:x]: stop_turn in before_tool_call also denies the pending
    # call, and steer, stop_turn and stop_generation do nothing once the
    # turn is over. Anywhere else (a command, an init task, a thread the
    # handler started) they act on the session now, through the Host.
    class Context
      # Thread.current key: {Context => the event its handler runs for}.
      CURRENT_EVENTS = Service::CURRENT_EVENTS
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

      # config.yml `bundles: <bundle>:` with the session's own values for
      # the bundle laid over it (chi --set BUNDLE.KEY=VALUE, through the
      # Host's setup: SessionSetup#bundle_settings), string keys, frozen.
      # Plugin init and chi.ctx run before the session is bound: with no
      # session id yet it is the config alone, and it is built again once
      # per session id (the session's values never change after it starts).
      # A plugin's initialize(settings) gets the config only: a value a
      # session may set is read here, at call time.
      # @return [Hash]
      def settings
        id = session_id
        cached = @session_settings
        return cached.last if cached && cached.first == id

        merged = id ? overlay(@settings, session_values) : @settings
        @session_settings = [id, merged].freeze
        merged
      end

      # @return [Logger]
      attr_reader :log

      # @param label [String] "<file> (bundle <name>)", what notices and
      #   questions are labelled by
      # @param host [Host]
      # @param sessions [Object, nil] what #sessions returns instead of a
      #   Sessions over +host+ (the test kit's recording one)
      # @param http_transport [#call, nil] what #http sends through instead
      #   of the network (the test kit's FakeHttp); the default cancel
      #   lookup stays the Context's own
      def initialize(bundle:, label:, settings:, host:, env: ENV, sessions: nil, http_transport: nil)
        @bundle = bundle.to_s
        @label = label
        @settings = deep_freeze(settings.is_a?(Hash) ? settings : {})
        @host = host
        @env = env
        @log = Logger.new(@bundle)
        @git = Guardrails::GitInfo.new
        @data_dir = nil
        @sessions = sessions
        @http_transport = http_transport
        @http = nil
      end

      # The bundle, never the environment it holds (every API key in it).
      def inspect = "#<#{self.class.name} bundle=#{@bundle}>"

      def pretty_print(printer) = printer.text(inspect)

      # @return [String, nil] the session's id (nil before the first one)
      def session_id = @host.session_id.call

      # @return [String, nil] the model the session runs on now: its
      #   resolved ref ("host:id"), right after /model too
      def model = @host.model_name&.call

      # @return [String, nil] the model's memory overlay key
      #   (`<name>.<key>.md`, ModelOverlay.key_for), as memory_write
      #   current_model_only names it
      def model_key = @host.model_key&.call

      # @return [SessionMetrics::Cost] the session's spend so far, read now:
      #   #total, #reported, #estimated, #side (Float USD) and #known?
      #   (docs/plugins.md); zero and known with no session
      def cost = @host.cost&.call || SessionMetrics::Cost.zero

      # @return [String, nil] the name of the session's toolkit ("full" for
      #   one from before toolkits; nil with no session)
      def toolkit = @host.toolkit&.call

      # @return [Array<String>] the tools the session's next turn declares
      #   (its toolkit resolved: a kit name says less than this)
      def declared_tools = Array(@host.declared_tools&.call)

      # Put the session on toolkit +name+ (a plugin's chi.toolkit, or
      # chi's): only before the session's first model reply and never while
      # a turn runs, since the declared tools start every request; it then
      # applies at the next turn's start, and the user is told. Otherwise
      # nothing changes and the plugin can say to run /toolkit NAME.
      # @return [Boolean] whether it was staged
      # @raise [ArgumentError] a toolkit no one declared
      def use_toolkit(name) = !!@host.use_toolkit&.call(name.to_s)

      # Whether the session is a `chi scratch` one (deleted when it ends).
      def scratch? = !!@host.scratch&.call

      # ctx.frontend's values, by the Engine's interface.
      FRONTENDS = { repl: :repl, non_interactive: :one_shot, worker: :worker }.freeze

      # What runs the session, read now (the host sets it after the plugins
      # load): :repl (the REPL, -p without --non-interactive), :one_shot
      # (-p --non-interactive: one turn, then exit) or :worker (a session
      # worker: the web, an attached TUI). A host without one is :worker.
      # @return [Symbol]
      def frontend = FRONTENDS.fetch(@host.frontend&.call, :worker)

      # Whether the session is a delegate child (Session#delegate?): a task
      # another session handed over, not the user's own.
      def delegate? = !!saved_session&.delegate?

      # Whether the session is a fork (ctx.sessions.fork: /btw keep, a
      # plugin's): it has a parent and isn't a delegate child, and it
      # started from a conversation, so its first prompt isn't its first
      # user message.
      def fork?
        session = saved_session
        !session.nil? && !session.parent_id.nil? && !session.delegate?
      end

      # @return [String] the session's working directory
      def cwd = @host.cwd.call || Dir.pwd

      # @return [String, nil] the git checkout holding #cwd
      def repo_root = @git.root(cwd)

      # $XDG_STATE_HOME/samagotchi/plugins/<bundle>/, created on first use.
      # @return [String]
      def data_dir
        @data_dir ||= File.join(Paths.state_dir(env: @env), "plugins", @bundle).tap { |dir| FileUtils.mkdir_p(dir) }
      end

      # The conversation so far, a frozen copy, without the system prompt.
      # While a turn runs, a session worker's (attached TUI, web) adds the
      # turn so far: its prompt, the model's text and the lines merged into
      # it; the REPL's is the conversation before that turn
      # (#messages_partial?).
      # @return [Array<Hash>]
      def messages
        Array(@host.messages.call).map { |message| message.dup.freeze }.freeze
      end

      # Whether #messages leaves out a running turn (the REPL mid-turn), so
      # a plugin can say what its answer is about.
      def messages_partial? = !!@host.messages_partial&.call

      # The files whose text the session's system prompt holds now, as
      # absolute paths in prompt order (SystemPrompt#prompt_files): the
      # AGENTS.md chain (the work tree top down to the cwd), then the
      # appended files (append_system_prompt:, --append-system-prompt).
      # [] before the first build and after one that drops them (a model
      # or tools change). A Host without the member (a spec's) reads [].
      # @return [Array<String>] frozen
      def prompt_files
        Array(@host.prompt_files&.call || []).freeze
      end

      # Run +block+ as this plugin's handler for +event+: until it returns,
      # the helpers called on this thread act as the event's own. Nests (a
      # fire inside a handler gets its own event; the outer one is back
      # after it); threads the block starts don't inherit it.
      # @param event [Hash] the fire's event
      def with_event(event)
        events = (Thread.current[CURRENT_EVENTS] ||= {}.compare_by_identity)
        had = events.key?(self)
        previous = events[self]
        events[self] = event
        yield
      ensure
        if had
          events[self] = previous
        else
          events&.delete(self)
        end
      end

      # One line to the user, labelled by the plugin (in every UI by its
      # bundle's name). Every UI shows it, during a turn or between turns.
      # @param level [Symbol] :info or :warn
      def notify(text, level: :info, fallback_for: nil)
        if (helper = event_helper(:notify))
          helper.call(text.to_s, level: level, fallback_for: fallback_for)
        else
          @host.notify.call(text.to_s, level, @label, fallback_for: fallback_for)
        end
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
      # @param model [String, nil] a configured model ("host:id", an alias,
      #   or a model id one of the hosts lists) instead of the session's:
      #   keys stay chi's config, a plugin never names a URL or a key
      # @return [String] the answer ("" when the model said nothing)
      # @raise [ArgumentError] no prompt, or a +model+ that names nothing configured
      # @raise [ModelError] the request failed or timed out
      # @raise [ModelCancelled] +cancel+ was cancelled
      def ask_model(messages:, prompt:, system: nil, timeout: 120, max_tokens: nil, cancel: nil, model: nil)
        raise ArgumentError, "ask_model needs a prompt" if prompt.to_s.strip.empty?
        raise ArgumentError, "ask_model's model: is a String like \"host:id\"" unless model.nil? || (model.is_a?(String) && !model.strip.empty?)

        request = SideQuestion.request(messages: messages, prompt: prompt, system: system)
        limit = max_tokens.nil? ? ASK_MAX_TOKENS : Integer(max_tokens)
        @host.ask_model.call(request, timeout: Float(timeout), max_tokens: limit, cancel_controller: cancel,
                                      model: model&.strip, source: @bundle).to_s
      rescue IdleClient::SummarizeError => e
        raise ModelError, e.message
      rescue LLM::RequestCancelled
        raise ModelCancelled, "the request was cancelled"
      end

      # ctx.ask_model's answer limit when none is given.
      ASK_MAX_TOKENS = 1024

      # Other sessions: fork one from a conversation, send one a message,
      # read one (Sessions).
      # @return [Sessions]
      def sessions
        @sessions ||= Sessions.new(@host)
      end

      # An HTTP client for calling services (Http, docs/plugins.md). A call
      # made for the turn (a tool, a handler) stops when the turn is stopped;
      # one from a command, a service or your own thread has only its
      # timeout unless it passes cancel:.
      # @return [Http]
      def http
        @http ||= Http.new(bundle: @bundle, transport: @http_transport,
                           cancel_lookup: -> { http_cancel_controller })
      end

      # This session's attached context: attach a URL or a command, list
      # (AttachedContext).
      # @return [AttachedContext]
      def context
        @context ||= AttachedContext.new(@host, bundle: @bundle)
      end

      # A single-select question through the question flow. Inside a
      # stream hook's handler (generation_progress) it asks no one (nil).
      # @return [Hash, nil] {selected:, freeform:, selected_indices:}, or nil
      #   (no one to ask, cancelled, bad options)
      def ask_user(question:, options:, header: nil, allow_freeform: false)
        if (helper = event_helper(:ask_user))
          return helper.call(question: question, options: options, header: header, allow_freeform: allow_freeform)
        end

        @host.ask_user.call(question: question, options: options, header: header, allow_freeform: allow_freeform,
                            hook: @label)
      end

      # Whether the running turn was cancelled (a long tool should stop).
      def cancelled? = !!@host.cancelled.call

      # Put +text+ into the running turn, as a user's steering does: at the
      # loop's next boundary (after the tool calls in flight) it joins the
      # conversation as its own user message, shown in every UI as a nudge
      # from this bundle. It never starts a turn. True means queued: if the
      # model answers first, or the turn ends, it is dropped (logged).
      # Callable from a handler (false from after_turn / session_end), a
      # command (an anytime one runs beside the turn) or your own thread.
      # @return [Boolean] whether a turn was running and the text queued
      def steer(text)
        helper = event_helper(:steer)
        return !!helper.call(text.to_s) if helper

        !!@host.steer&.call(text.to_s, @label)
      end

      # Stop the running turn, after a notice with +reason+. From a
      # before_tool_call handler it also denies the pending call; from
      # after_turn / session_end it does nothing (false).
      # @return [Boolean] whether a running turn was stopped now
      def stop_turn(reason)
        helper = event_helper(:stop_turn)
        return !!helper.call(reason.to_s) if helper

        !!@host.stop_turn&.call(reason.to_s, @label)
      end

      # Cut the generation that is streaming: the turn goes on and the
      # model is asked again (retry.empty_answer), or with no retry left
      # the turn ends as cancelled (hook). Shows nothing: post your own
      # notice. From after_turn / session_end it does nothing (false).
      # @return [Boolean] whether a streaming generation was cut now
      def stop_generation(reason)
        helper = event_helper(:stop_generation)
        return !!helper.call(reason.to_s) if helper

        !!@host.stop_generation&.call(reason.to_s, @label)
      end

      private

      # Whether this plugin's handler runs on this thread (#with_event).
      def in_handler? = !!Thread.current[CURRENT_EVENTS]&.key?(self)

      # The controller a ctx.http call without cancel: stops with: nil inside
      # a service's start block, even on the turn's thread.
      def http_cancel_controller
        Service.starting? ? nil : @host.cancel_controller&.call(handler: in_handler?)
      end

      # The event[:x] helper of the event this plugin's handler runs for on
      # this thread, or nil (not in a handler).
      def event_helper(name)
        event = Thread.current[CURRENT_EVENTS]&.[](self)
        helper = event[name] if event.is_a?(Hash)
        helper.respond_to?(:call) ? helper : nil
      end

      # The session's file as saved, nil without an id or a file.
      def saved_session
        id = session_id
        return nil unless id

        Session.load(id, state_dir: @host.state_dir&.call || Session.default_state_dir)
      rescue ArgumentError
        nil
      end

      # The session's own values for this bundle ({} without any, or when
      # the Host can't tell them).
      def session_values
        values = @host.setup&.call&.bundle_settings
        values.is_a?(Hash) ? values.fetch(@bundle, {}) : {}
      rescue StandardError => e
        @log.warn("session_settings_unread", error: "#{e.class}: #{e.message}")
        {}
      end

      def overlay(config, values)
        values.empty? ? config : deep_freeze(config.merge(values))
      end

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
