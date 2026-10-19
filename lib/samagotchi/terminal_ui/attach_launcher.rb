# frozen_string_literal: true

require_relative "../session"
require_relative "../config"
require_relative "../model_profile"
require_relative "../session_manager"
require_relative "../thinking_command"
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
      # @param appended_prompt_files [Array<String>] --append-system-prompt's
      #   files (absolute): a new session's setup carries them
      # @param llm_context [Hash{Symbol => String}] --llm-context* as typed
      #   (LLMContextOverride.update): a new session starts with them; a
      #   resumed or attached one's worker gets a /llm-context, after the
      #   /model
      # @param thinking [String, nil] --thinking as typed: a new session
      #   starts with it as its own level; a resumed or attached one's
      #   worker gets a /thinking, after those
      # @param toolkit [Toolkit, nil] --toolkit/--tool/--no-tool: a new
      #   session's toolkit (config's toolkit.default without); an existing
      #   session keeps its own
      # @param toolkit_flags [Array<String>] which of those were given, for
      #   the line an existing session's run prints (--set too)
      # @param bundle_settings [Hash] --set's values (BundleSessionSettings):
      #   a new session's setup carries them; an existing session keeps its own
      # @param parent_answers [String, nil] --parent-answers: a new session's
      #   own guardrails.parent_answers; an existing session keeps its own
      #   (never sent as a /parent-answers command: that would be a
      #   loosening route from a command line)
      # @param state_dir [String, nil] where the sessions are (the default
      #   state dir by default): the worker's, for the attached loop too
      # @return [Symbol] :detached, :closed when the worker went away,
      #   :failed when the --model switch didn't go through, or (input from a
      #   pipe) :turn_failed / :empty_answer / :unanswered (AttachedLoop#run)
      def run(attach: nil, shared: false, resume: nil, prompt: nil, model: nil, no_interrupt: false, default_input: true,
              memories: [], muted_memories: [], llm_context: {}, thinking: nil, appended_prompt_files: [], toolkit: nil,
              toolkit_flags: [], bundle_settings: {}, parent_answers: nil, state_dir: nil)
        state_dir ||= Session.default_state_dir
        client = connect(attach: attach, shared: shared, resume: resume, model: model, state_dir: state_dir,
                         memories: memories, muted_memories: muted_memories, llm_context: llm_context, thinking: thinking,
                         appended_prompt_files: appended_prompt_files, toolkit: toolkit, toolkit_flags: toolkit_flags,
                         bundle_settings: bundle_settings, parent_answers: parent_answers)
        commands = []
        commands << "/model #{model}" if model && (attach || resume)
        commands << LLMContextOverride.command_line(llm_context) if (attach || resume) && !llm_context.empty?
        # --yes: typing the flag is the choice (no confirm step).
        commands << "#{ThinkingCommand::NAME} #{thinking} --yes" if (attach || resume) && thinking
        first_command = commands.size > 1 ? commands : commands.first
        surface = open_surface
        attached = AttachedLoop.new(client: client, screen: surface, client_id: "tui:#{Process.pid}", first_prompt: prompt,
                                    first_command: first_command, no_interrupt: no_interrupt,
                                    default_input: default_input && !prompt && !attach && !resume,
                                    wait_at_eof: !$stdin.tty?,
                                    as_parent: Guardrails::ParentApprovals.parent_process?, state_dir: state_dir)
        ended = begin
          attached.run
        ensure
          close_surface(surface)
        end
        if ended == :unanswered && attached.unanswered
          report_unanswered(attached.unanswered, session_id: client.session_id, state_dir: state_dir)
        end
        report_ended(ended)
        ended
      end

      # A question left waiting (exit 3), in full on stderr as `chi send
      # --wait` prints it (ParentReport), so a script or a parent agent
      # can answer it with chi answer.
      # @param pending [Hash] the pending question as the Bridge sent it
      # @param state_dir [String, nil] where the session file is: what a
      #   parent may pick follows its own parent_answers too
      def report_unanswered(pending, session_id:, err: $stderr, state_dir: nil)
        question = PendingQuestion.from_file(pending)
        strategy = ParentReport.strategy_for(session_id, state_dir: state_dir || Session.default_state_dir)
        err.print("chi: #{ParentReport.question_text(question, session_id: session_id, strategy: strategy)}")
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
                  memories: [], muted_memories: [], llm_context: {}, thinking: nil, appended_prompt_files: [], toolkit: nil,
                  toolkit_flags: [], bundle_settings: {}, parent_answers: nil, err: $stderr)
        sd = state_dir || Session.default_state_dir
        if attach || resume
          warn_memory_flags_ignored(attach || resume, memories, muted_memories, err, appended_prompt_files: appended_prompt_files,
                                                                                     toolkit_flags: toolkit_flags)
        end
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
                                                 memories: memories, muted_memories: muted_memories,
                                                 setup: SessionSetup.new(llm_context: llm_context.empty? ? nil : LLMContextOverride.update(nil, llm_context),
                                                                         thinking: Thinking.session_level(thinking),
                                                                         appended_prompt_files: appended_prompt_files,
                                                                         toolkit: toolkit, bundle_settings: bundle_settings,
                                                                         parent_answers: parent_answers))
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
      # --memory/--mute/--append-system-prompt and the toolkit flags given
      # with --attach or --resume are ignored, with a line saying so (printed
      # before the live region opens).
      def warn_memory_flags_ignored(session_id, memories, muted_memories, err, appended_prompt_files: [], toolkit_flags: [])
        flags = []
        flags << "--memory" unless Array(memories).empty?
        flags << "--mute" unless Array(muted_memories).empty?
        flags << "--append-system-prompt" unless Array(appended_prompt_files).empty?
        flags.concat(toolkit_flags)
        return if flags.empty?

        verb = flags.size == 1 ? "applies" : "apply"
        names = flags.size > 2 ? "#{flags[0..-2].join(", ")} and #{flags.last}" : flags.join(" and ")
        err.puts "(#{names} #{verb} to a new session; #{session_id} keeps its own)"
      end

      # @return [BridgeClient, nil] the running worker's, or nil when none runs
      def connect_existing(session_id, state_dir)
        Session.load(session_id, state_dir: state_dir)
        BridgeClient.discover(session_id, session_dir: Session.session_dir(session_id, state_dir: state_dir))
      end
    end
  end
end
