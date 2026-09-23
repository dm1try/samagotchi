# frozen_string_literal: true

require_relative "../session"
require_relative "../config"
require_relative "../model_profile"
require_relative "../session_manager"
require_relative "../bridge_client"
require_relative "live_region"
require_relative "plain_surface"
require_relative "attached_loop"

module Samagotchi
  class TerminalUI
    # `chi --attach ID` and `chi --shared [--resume ID]`: find or start the
    # session's worker, then run the TUI as a client of its Bridge
    # (AttachedLoop). It takes no OwnerLock and builds no Engine: the worker
    # owns the session, and any number of UIs can attach to it.
    module AttachLauncher
      # Why attaching failed, worded for the terminal.
      class Error < StandardError; end

      BRIDGE_WAIT = 10.0

      module_function

      # Attach until the user detaches or the worker goes away.
      # @param prompt [String, nil] sent as the first prompt once attached (`-p`)
      # @param model [String, nil] --model: a new session starts on it; a
      #   resumed or attached one's worker gets a /model before the prompt
      # @param no_interrupt [Boolean] --no-interrupt: every turn this TUI
      #   posts runs with the raised iteration limit
      # @param default_input [Boolean] a new session with no -p gets
      #   SAMAGOTCHI_DEFAULT_INPUT in its first read (--no-default-input: no)
      # @return [Symbol] :detached, :closed when the worker went away, or
      #   :failed when the --model switch didn't go through
      def run(attach: nil, shared: false, resume: nil, prompt: nil, model: nil, no_interrupt: false, default_input: true)
        client = connect(attach: attach, shared: shared, resume: resume, model: model)
        first_command = model && (attach || resume) ? "/model #{model}" : nil
        surface = open_surface
        begin
          AttachedLoop.new(client: client, screen: surface, client_id: "tui:#{Process.pid}", first_prompt: prompt,
                           first_command: first_command, no_interrupt: no_interrupt,
                           default_input: default_input && !prompt && !attach && !resume).run
        ensure
          close_surface(surface)
        end
      end

      # A live region (Screen, with Reline drawing into it) on a terminal
      # that can show one, else plain append-only output.
      # @return [Screen, PlainSurface]
      def open_surface(out: $stdout, input: $stdin, env: ENV)
        LiveRegion.open(out: out, input: input, env: env) || PlainSurface.new(out: out)
      end

      def close_surface(surface)
        LiveRegion.close(surface)
      end

      # @return [BridgeClient] a client for the live Bridge of the session
      # @raise [Error]
      def connect(attach: nil, shared: false, resume: nil, model: nil, state_dir: nil, wait: BRIDGE_WAIT)
        sd = state_dir || Session.default_state_dir
        if attach
          live = connect_existing(attach, sd)
          return live if live

          # Its worker exited when nobody used it (or never ran): wake one.
          resume = attach
        end

        session = if resume
                    SessionManager.resume_session(resume, state_dir: sd)
                  else
                    SessionManager.spawn_session(prompt: nil, model_name: model && model_ref(model), state_dir: sd)
                  end
        client = BridgeClient.wait_for(session.id, session_dir: Session.session_dir(session.id, state_dir: sd), timeout: wait)
        client || raise(Error, "the worker for session #{session.id} did not start its Bridge in time")
      rescue SessionManager::OwnedByTUI
        raise Error, "session #{resume} is open in a chi REPL; close it there first"
      rescue ArgumentError => e
        raise Error, e.message
      end

      # --model as the REPL reads it: an alias resolved, a host prefix kept.
      def model_ref(model)
        ModelProfile.required_model_name(ConfigFile.resolve_model_alias(model))
      end

      # @return [BridgeClient, nil] the running worker's, or nil when none runs
      def connect_existing(session_id, state_dir)
        Session.load(session_id, state_dir: state_dir)
        BridgeClient.discover(session_id, session_dir: Session.session_dir(session_id, state_dir: state_dir))
      end
    end
  end
end
