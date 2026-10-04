# frozen_string_literal: true

require_relative "../session"
require_relative "../config"
require_relative "../model_profile"
require_relative "../session_manager"
require_relative "../bridge_client"
require_relative "../parent_report"
require_relative "../cli/exit"
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
      # @param memories [Array<String>] --memory: a new session's worker
      #   preloads them (an existing session keeps its own list)
      # @param muted_memories [Array<String>] --mute: hidden from a new session
      # @return [Symbol] :detached, :closed when the worker went away,
      #   :failed when the --model switch didn't go through, or (input from a
      #   pipe) :turn_failed / :empty_answer / :unanswered (AttachedLoop#run)
      def run(attach: nil, shared: false, resume: nil, prompt: nil, model: nil, no_interrupt: false, default_input: true,
              memories: [], muted_memories: [])
        client = connect(attach: attach, shared: shared, resume: resume, model: model,
                         memories: memories, muted_memories: muted_memories)
        first_command = model && (attach || resume) ? "/model #{model}" : nil
        surface = open_surface
        attached = AttachedLoop.new(client: client, screen: surface, client_id: "tui:#{Process.pid}", first_prompt: prompt,
                                    first_command: first_command, no_interrupt: no_interrupt,
                                    default_input: default_input && !prompt && !attach && !resume,
                                    wait_at_eof: !$stdin.tty?,
                                    parent_answers: Guardrails::ParentApprovals.parent_process?)
        ended = begin
          attached.run
        ensure
          close_surface(surface)
        end
        report_unanswered(attached.unanswered, session_id: client.session_id) if ended == :unanswered && attached.unanswered
        report_ended(ended)
        ended
      end

      # A question left waiting (exit 3), in full on stderr as `chi send
      # --wait` prints it (ParentReport), so a script or a parent agent
      # can answer it with chi answer.
      # @param pending [Hash] the pending question (symbol keys)
      def report_unanswered(pending, session_id:, err: $stderr)
        err.print("chi: #{ParentReport.question_text(pending, session_id: session_id)}")
        err.flush
      end

      # A turn of ours that ended with no answer (input from a pipe): one
      # line on stderr, as the in-process `chi -p --non-interactive` says
      # it, so a script doesn't take the silence for an answer (exit 1).
      def report_ended(ended, err: $stderr)
        err.puts(TerminalUI::EMPTY_ANSWER_ERROR) if ended == :empty_answer
      end

      # chi's exit status after #run: 0 detached, 3 a question left waiting
      # for an answer (input from a pipe ran out; chi --attach or chi answer
      # answers it), 1 anything else (a failed turn, an empty answer, the
      # worker gone).
      # @param ended [Symbol] what #run returned
      # @return [Integer]
      def exit_status(ended)
        case ended
        when :detached then CLI::Exit::OK
        when :unanswered then CLI::Exit::QUESTION
        else CLI::Exit::FAILED
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
      def connect(attach: nil, shared: false, resume: nil, model: nil, state_dir: nil, wait: BRIDGE_WAIT,
                  memories: [], muted_memories: [], err: $stderr)
        sd = state_dir || Session.default_state_dir
        warn_memory_flags_ignored(attach || resume, memories, muted_memories, err) if attach || resume
        if attach
          live = connect_existing(attach, sd)
          return live if live

          # Its worker exited when nobody used it (or never ran): wake one.
          resume = attach
        end

        session = if resume
                    SessionManager.resume_session(resume, state_dir: sd)
                  else
                    SessionManager.spawn_session(prompt: nil, model_name: model && model_ref(model), state_dir: sd,
                                                 memories: memories, muted_memories: muted_memories)
                  end
        client = BridgeClient.wait_for(session.id, session_dir: Session.session_dir(session.id, state_dir: sd), timeout: wait)
        client || raise(Error, "the worker for session #{session.id} did not start its Bridge in time")
      rescue SessionManager::OwnedByTUI
        raise Error, "session #{resume} is open in a chi REPL; close it there first"
      rescue ArgumentError => e
        raise Error, e.message
      end

      # --model as typed: spawn_session stores the resolved ref and this name.
      def model_ref(model)
        ModelProfile.required_model_name(model)
      end

      # An existing session's prompt is built from its own session fields:
      # --memory/--mute given with --attach or --resume are ignored, with a
      # line saying so (printed before the live region opens).
      def warn_memory_flags_ignored(session_id, memories, muted_memories, err)
        flags = []
        flags << "--memory" unless Array(memories).empty?
        flags << "--mute" unless Array(muted_memories).empty?
        return if flags.empty?

        verb = flags.size == 1 ? "applies" : "apply"
        err.puts "(#{flags.join(' and ')} #{verb} to a new session; #{session_id}'s prompt is already built)"
      end

      # @return [BridgeClient, nil] the running worker's, or nil when none runs
      def connect_existing(session_id, state_dir)
        Session.load(session_id, state_dir: state_dir)
        BridgeClient.discover(session_id, session_dir: Session.session_dir(session_id, state_dir: state_dir))
      end
    end
  end
end
