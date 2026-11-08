# frozen_string_literal: true

module Samagotchi
  class Engine
    # Side requests: a plugin's ctx.ask_model and Check this on their own
    # IdleClient, their usage in the session's side line, and System 1's
    # recording of judged asks. Writes @side_client/@side_client_key (under
    # @side_client_mutex); reads @metrics, @session, @host_registry.
    # The recorder (SystemOne::Recorder) is the turn stages' recording seam.
    module SideRequestsPart
      # Count one side request (a recap, a plugin's ctx.ask_model: IdleClient's
      # on_usage) in the session's side line, apart from its turns' totals.
      # Folded and announced as :side_usage under the event lock, so the side
      # blocks reach the UIs in fold order (the lock order event lock →
      # metrics mutex is the existing one); then, between turns, saved to
      # analytics.json (a running turn's end or checkpoint saves it), unless
      # the session is gone (no session file: a late recap thread must not
      # recreate a deleted session's folder; the folder itself may not exist
      # yet before a first turn). Safe from any thread: the recap's, a
      # plugin's, the turn's.
      # A side request counts against the participant who caused it
      # (#side_author), its usage's own author when it names one.
      # @param usage [SideUsage]
      # @return [void]
      def note_side_usage(usage)
        usage = usage.with(author: side_author(usage.kind)) if usage.author.nil?
        synchronize_events do
          block = @metrics.add_side(usage)
          @session_observer.notify(type: :side_usage, kind: usage.kind, side: block)
        end
        sid = @metrics.session_id
        return if sid.nil? || turn_running?
        return unless File.exist?(Session.session_file(sid, state_dir: session_state_dir))

        @metrics.persist(state_dir: session_state_dir)
      end

      # Who caused a side request of +kind+ now: the running turn's author (a
      # plugin's ctx.ask_model in it), the last turn's for the idle recap
      # (it recaps that turn); nil, the owner's, for anything else (an owner
      # command's ask_model between turns).
      # @return [String, nil]
      def side_author(kind)
        # Check this is only ever the owner's, whichever turn runs as it ends.
        return nil if kind.to_s == ObjectivesCheck::SOURCE

        # One read each of the published contexts (TurnState): any thread.
        running = turn_context
        return running.author if running

        kind.to_s == RECAP_SIDE_KIND ? last_turn_context&.author : nil
      end

      private

      # +client+ (nil for none) saving its asks as +judgment+'s runs
      # (SystemOne::Recorder#wrap, over a recorder built now): the
      # guardrails' System 1 client. No client or a scratch session: the
      # client as it is, with nothing read (no recorder built).
      # @param mode [String, nil] the use's mode, for its runs (Recording.wrap)
      def system_one_recording(client, judgment, session, mode: nil)
        return client if client.nil? || session&.scratch

        system_one_recorder.wrap(client, judgment, session, mode: mode)
      end
      private :system_one_recording

      # What a turn stage saves its System 1 asks with (SystemOne::Recorder):
      # this Engine's runs and the model it names now, read at this call and
      # never kept, so each stage call sees the model as it is then (an
      # outgoing ask after a before_turn hook's switch, the new one). Never
      # raises: on a failure, SystemOne::Recorder::NONE (no runs, the plain
      # client), said once per failure as before.
      # @return [SystemOne::Recorder]
      def system_one_recorder
        SystemOne::Recorder.new(runs: system_one_runs, session_model: effective_model_name)
      rescue StandardError => e
        SystemOne::Recorder.failed(e)
        SystemOne::Recorder::NONE
      end
      private :system_one_recorder

      # Where this Engine's runs are saved; read each time, as the settings are.
      def system_one_runs = SystemOne::Runs.for_sessions_dir(session_state_dir)
      private :system_one_runs

      # ctx.ask_model's request: the session's current model on its host, as
      # a turn resolves them (a /model switch counts), or a configured +model+
      # (a host:id ref, an alias, a bare id one of a host's models), through its own
      # IdleClient, so it shares nothing with the turn's backend. The client
      # is kept while the target and timeout stay (what it learned, e.g. a
      # refused thinking-off, holds for the next request); the session's id
      # goes with the request. Its usage counts in the session's side line
      # (#note_side_usage) under +source+, the asking bundle's name.
      # @return [String] the answer
      def ask_side_model(request, timeout:, max_tokens:, cancel_controller:, model: nil, source: nil)
        target = model.nil? ? session_model_recap_target : configured_side_target(model)
        client = side_model_client(target, timeout)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        answer = client.ask(request, max_tokens: max_tokens, cancel_controller: cancel_controller, session_id: @session&.id,
                                     kind: source.to_s.empty? ? "ask" : source.to_s, on_usage: method(:note_side_usage))
        Log.info(:plugins, "ask_model", model: target.label, answer_model: answer.model, chars: answer.text.length,
                                        ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
        answer.text
      end
      private :ask_side_model

      # The target of ctx.ask_model(model:): +model+ as a turn resolves it,
      # once it is known to name something configured. IdleTarget.of_model
      # never raises (an unknown host falls to the default host, an unknown id
      # to the default entry), so a typo would silently ask another model.
      # @raise [ArgumentError] +model+ names no configured host and is no
      #   host's model (cached, declared or saved lists; nothing is asked)
      def configured_side_target(model)
        ref = @host_registry.model_ref(model)
        unless ref.host_name || ref.alias_name || @host_registry.hosts_with_model(ref.id).any?
          raise ArgumentError, "ask_model: unknown model #{model.to_s.inspect} (use a configured host:id, an alias, " \
                               "or a model id one of your hosts lists)"
        end

        IdleTarget.of_model(@host_registry, model)
      end
      private :configured_side_target

      # The IdleClient for +target+ at +timeout+: the last one when both are
      # the same, else a new one.
      def side_model_client(target, timeout)
        @side_client_mutex.synchronize do
          key = [target, timeout]
          unless @side_client && @side_client_key == key
            @side_client = IdleClient.for(target, timeout: timeout)
            @side_client_key = key
          end
          @side_client
        end
      end
      private :side_model_client

      # The session's current model as a recap target: its host's OpenAI API
      # (native llama.cpp hosts serve /v1/chat/completions too), key variable
      # and bare model name, as a turn resolves them.
      # @return [IdleTarget]
      def session_model_recap_target
        IdleTarget.of_model(@host_registry, effective_model_name)
      end
    end
  end
end
