# frozen_string_literal: true

require_relative "../session"
require_relative "../config"
require_relative "../model_profile"
require_relative "../session_manager"
require_relative "../thinking_command"
require_relative "../bridge_client"
require_relative "../worker_link"
require_relative "../worker_presence"
require_relative "../parent_report"
require_relative "../cli/exit"
require_relative "../launch_mode"
require_relative "live_region"
require_relative "plain_surface"
require_relative "attached_loop"
require_relative "log_tail"
require_relative "formatting"

module Samagotchi
  class TerminalUI
    # `chi`, `chi --attach ID` and `chi --resume ID`: find or start the
    # session's worker, then run the TUI as a client of its Bridge
    # (AttachedLoop). It takes no OwnerLock and builds no Engine: the worker
    # owns the session, and any number of UIs can attach to it.
    module AttachLauncher
      # #paint, for the -v records.
      extend Formatting

      # Why attaching failed, worded for the terminal.
      class Error < StandardError; end

      BRIDGE_WAIT = 10.0
      # A connector that answered no session (its own failures raise Error
      # with their words).
      NOTHING_CONNECTED = "could not attach: no session was found or started"
      # `chi scratch`'s first line, and its last once the session is gone.
      SCRATCH_BANNER = "Scratch session: nothing is kept, it is deleted when you leave."
      SCRATCH_DELETED = "Scratch session deleted."
      # chi -v on a worker that was running before this launch (%s: the
      # debug log): its level is its own.
      VERBOSE_RUNNING = "(--verbose: this worker was already running and logs at the level it started with; " \
                        "its records show here only if it writes to %s: one chi web started may log elsewhere)"

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
      # @param settings [SessionConfig::Settings, nil] --set's values:
      #   a new session's setup carries them; an existing session keeps its own
      # @param parent_answers [String, nil] --parent-answers: a new session's
      #   own guardrails.parent_answers; an existing session keeps its own
      #   (never sent as a /parent-answers command: that would be a
      #   loosening route from a command line)
      # @param scratch [Boolean] `chi scratch`: a new scratch session (its
      #   worker's Engine saves nothing), stopped and deleted however the
      #   attach ends; its worker deletes it too once no client is left
      # @param verbose [Boolean] -v: the session's debug records in the
      #   debug log (Log.path), shown above the live region as they come
      #   (LogTail); a worker this launch spawns logs at debug (bin/chi's
      #   log.level override reaches it through Config.cli_env)
      # @param state_dir [String, nil] where the sessions are (the default
      #   state dir by default): the worker's, for the attached loop too
      # @param connector [#connect, nil] finds or starts the session
      #   elsewhere: its #connect returns the AttachLink the loop runs on
      #   (nil: this machine's, through .connect; a connector never falls
      #   back to it), and its #client_id, when it has one, names this
      #   TUI's streams and requests there (#client_id)
      # @return [Symbol] :detached, :closed when the worker went away,
      #   :failed when the --model switch didn't go through, or (input from a
      #   pipe) :turn_failed / :empty_answer / :removed / :unanswered
      #   (AttachedLoop#run)
      def run(attach: nil, resume: nil, prompt: nil, model: nil, no_interrupt: false, default_input: true,
              memories: [], muted_memories: [], llm_context: {}, thinking: nil, appended_prompt_files: [], toolkit: nil,
              toolkit_flags: [], settings: nil, parent_answers: nil, scratch: false, verbose: false, state_dir: nil,
              connector: nil)
        state_dir ||= Session.default_state_dir
        running_before = verbose && !connector && worker_running?(attach || resume, state_dir)
        link = connector && (connector.connect || raise(Error, NOTHING_CONNECTED))
        client = if connector
                   link.client
                 else
                   connect(attach: attach, resume: resume, model: model, state_dir: state_dir,
                           memories: memories, muted_memories: muted_memories, llm_context: llm_context,
                           thinking: thinking, appended_prompt_files: appended_prompt_files, toolkit: toolkit,
                           toolkit_flags: toolkit_flags, settings: settings, parent_answers: parent_answers,
                           scratch: scratch)
                 end
        $stdout.puts(SCRATCH_BANNER) if scratch
        commands = []
        # --yes on /model and /thinking: typing the flag is the choice (no
        # confirm step); its applied reply ends the launch's command.
        commands << "/model #{model} --yes" if model && (attach || resume)
        commands << LLMContextOverride.command_line(llm_context) if (attach || resume) && !llm_context.empty?
        commands << "#{ThinkingCommand::NAME} #{thinking} --yes" if (attach || resume) && thinking
        first_command = commands.size > 1 ? commands : commands.first
        $stderr.puts(format(VERBOSE_RUNNING, Log.path)) if running_before
        surface = open_surface
        tail = (start_log_tail(surface, client.session_id) if verbose && Log.path)
        options = { screen: surface, client_id: client_id(connector), first_prompt: prompt,
                    first_command: first_command, no_interrupt: no_interrupt,
                    default_input: default_input && !prompt && !attach && !resume,
                    wait_at_eof: !$stdin.tty?, scratch: scratch,
                    as_parent: Guardrails::ParentApprovals.parent_process? }
        attached = if connector
                     AttachedLoop.new(link: link, **options)
                   else
                     AttachedLoop.new(client: client, **options, state_dir: state_dir)
                   end
        ended = begin
          attached.run
        ensure
          tail&.stop
          close_surface(surface)
        end
        if ended == :unanswered && attached.unanswered
          # A link's strategy is read where the session is, now (L4), its
          # commands spelled its way.
          where = connector ? { strategy: link.parent_strategy, via: link.via } : {}
          report_unanswered(attached.unanswered, session_id: client.session_id, state_dir: state_dir, **where)
        end
        report_ended(ended)
        ended
      ensure
        link&.close
        # Every way out (Ctrl-D, /exit, the worker gone, an error, Ctrl-C or
        # a signal): only kill -9 leaves it to its worker (and the sweep).
        end_scratch(client.session_id, state_dir: state_dir, quiet: !$!.nil?) if scratch && client
      end

      # Whether +session_id+'s worker runs now (nil: a new session).
      def worker_running?(session_id, state_dir)
        return false unless session_id && Session.valid_id?(session_id)

        WorkerPresence.read(session_id, state_dir: state_dir, link: :look).live?
      end

      # The session's debug records, dim, above the live region.
      def start_log_tail(surface, session_id)
        LogTail.new(path: Log.path, session_id: session_id, on_record: lambda { |record|
          surface.commit(paint(LogLine.format(record).chomp, 2))
        }).start
      end

      # Stop the scratch session's worker and delete the session; its worker
      # may have deleted it first (it found no client left).
      def end_scratch(session_id, state_dir:, quiet: false, out: $stdout, err: $stderr)
        SessionManager.delete_session(session_id, state_dir: state_dir, stop: true, wait: LocalLink::DELETE_WAIT)
        out.puts(SCRATCH_DELETED) unless quiet
      rescue ArgumentError
        out.puts(SCRATCH_DELETED) unless quiet
      rescue SessionManager::DeleteRefused, SystemCallError => e
        err.puts("Scratch session #{session_id} was not deleted (#{e.message}): chi sessions delete #{session_id}")
      end

      # This TUI's client id: tui:PID, or the connector's own (a remote one
      # adds the host, for the UIs there).
      def client_id(connector)
        return connector.client_id if connector.respond_to?(:client_id)

        "tui:#{Process.pid}"
      end

      # A question left waiting (exit 3), in full on stderr as `chi send
      # --wait` prints it (ParentReport), so a script or a parent agent
      # can answer it with chi answer.
      # @param pending [Hash] the pending question as the Bridge sent it
      # @param state_dir [String, nil] where the session file is: what a
      #   parent may pick follows its own parent_answers too
      # @param strategy [Guardrails::ParentPolicy::Strategy, nil] that
      #   strategy, read already (an AttachLink's); nil:
      #   ParentReport.strategy_for here
      # @param via [ChiInvocation, nil] how its commands are spelled (nil:
      #   this machine's)
      def report_unanswered(pending, session_id:, err: $stderr, state_dir: nil, strategy: nil, via: nil)
        question = PendingQuestion.from_file(pending)
        strategy ||= ParentReport.strategy_for(session_id, state_dir: state_dir || Session.default_state_dir)
        words = via ? { via: via } : {}
        err.print("chi: #{ParentReport.question_text(question, session_id: session_id, strategy: strategy, **words)}")
        err.flush
      end

      # An own turn with no answer, or a prompt removed before it ran
      # (input from a pipe): one line on stderr, so a script doesn't take
      # the silence for an answer (exit 1).
      def report_ended(ended, err: $stderr)
        case ended
        when :empty_answer then err.puts(TerminalUI::EMPTY_ANSWER_ERROR)
        when :removed then err.puts("chi: the prompt was removed before it ran")
        end
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
      def connect(attach: nil, resume: nil, model: nil, state_dir: nil, wait: BRIDGE_WAIT,
                  memories: [], muted_memories: [], llm_context: {}, thinking: nil, appended_prompt_files: [], toolkit: nil,
                  toolkit_flags: [], settings: nil, parent_answers: nil, scratch: false, err: $stderr)
        sd = state_dir || Session.default_state_dir
        connected = false
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

        await_leaving_worker(resume, sd, err) if resume
        session = if resume
                    SessionManager.resume_session(resume, state_dir: sd)
                  else
                    SessionManager.spawn_session(prompt: nil, model_name: model && model_ref(model), state_dir: sd,
                                                 memories: memories, muted_memories: muted_memories,
                                                 setup: SessionSetup.new(llm_context: llm_context.empty? ? nil : LLMContextOverride.update(nil, llm_context),
                                                                         thinking: Thinking.session_level(thinking),
                                                                         appended_prompt_files: appended_prompt_files,
                                                                         toolkit: toolkit, settings: settings,
                                                                         parent_answers: parent_answers),
                                                 scratch: scratch)
                  end
        link = WorkerLink.await(session.id, session_dir: Session.session_dir(session.id, state_dir: sd), timeout: wait)
        raise(Error, format(LaunchMode::BRIDGE_LATE, session.id)) unless link.live?

        connected = true
        link.client(session.id)
      rescue SessionManager::OwnedByTUI => e
        raise Error, e.message
      rescue ArgumentError => e
        raise Error, e.message
      ensure
        # A scratch session whose Bridge never came (or Ctrl-C meanwhile).
        end_scratch(session.id, state_dir: sd, quiet: true, err: err) if scratch && session && !connected
      end

      # The session's previous worker may still be leaving: its Bridge
      # closed, the lock held while it writes its recap on leave (a resume
      # now would start nothing, the lock taken). Wait for it to let go
      # (OwnerLock.await_release), with one line saying so; any other owner
      # is left to resume_session as before.
      def await_leaving_worker(session_id, state_dir, err)
        OwnerLock.await_release(Session.session_dir(session_id, state_dir: state_dir),
                                on_wait: ->(_owner) { err.puts(LaunchMode::RECAP_WAIT) })
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
      # @raise [Error] its worker is newer than this chi (Skew)
      def connect_existing(session_id, state_dir)
        Session.load(session_id, state_dir: state_dir)
        link = WorkerPresence.read(session_id, state_dir: state_dir, link: :unlink).link
        raise Error, link.message(session_id) if link.is_a?(WorkerLink::Skew)

        link.live? ? link.client(session_id) : nil
      end
    end
  end
end
