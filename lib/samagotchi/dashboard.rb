# frozen_string_literal: true

require "samagotchi/session_manager"
require_relative "output_formatter"

module Samagotchi
  # Dashboard — a thin menu loop for managing background sessions.
  #
  # Step 1: render the numbered session list, spawn a new session from a typed
  # line, route numeric lines to the #attach_to seam, and support /quit.
  #
  # Step 2: #attach_to now runs the real attach loop — load (resuming the worker
  # if needed) the selected session through the injected manager, print an
  # on-disk conversation header and history, send messages via file IPC, and
  # render new output as it arrives, leaving via /detach, /stop, /quit, EOF, or
  # an automatic terminal-state detach.
  #
  # The dashboard is intentionally thin. It never constructs an Engine, spawns
  # an inline agent loop, or reaches into TerminalUI. It only talks to a
  # duck-typed manager object (responding to #list_sessions / #spawn_session /
  # #resume_session / #read_responses / #write_turn_input / #stop_session /
  # #wait_for_session), which keeps the menu + attach loops fork-free in specs.
  class Dashboard
    BANNER = "Chi Dashboard"

    # Hint shown after every render while the menu is active.
    HELP_HINT = <<~HINT.strip

      Start a session by typing a message, type a number to attach, /quit to exit.
    HINT

    # Hint shown when there are no sessions to list yet.
    EMPTY_HINT = <<~HINT.strip

      No sessions yet. Type a message to start one; /quit to exit.
    HINT

    # last_prompt preview cap (chars) before truncating with an ellipsis.
    PREVIEW_CHARS = 40

    # Characters kept from a session id when rendering a "short id".
    SHORT_ID_CHARS = 8

    # Poll bounds for the attach send/display cycle. A model/LLM turn can take
    # many seconds, so this is a generous-timeout bounded poll (never a fixed
    # short sleep) plus a hard iteration cap so attach can never hang.
    POLL_TIMEOUT_SECONDS = 60
    POLL_ITERATION_CAP = 10_000

    # Default manager: the SessionManager class responds to its own class
    # methods (list_sessions / spawn_session), so injection is duck-typed.
    #
    # +state_dir:+ is optional; when nil the manager defaults to
    # Session.default_state_dir. Threaded into attach calls for test isolation
    # with custom session stores.
    def initialize(manager: nil, state_dir: nil)
      @manager = manager || Samagotchi::SessionManager
      @state_dir = state_dir
    end

    # Print the banner + session list, then read one line at a time until EOF
    # (/quit or Ctrl+D). Returns rather than exiting (bin/chi handles exit).
    def run
      loop do
        render_list
        # :stop is returned only on EOF (nil) or /quit; :stay/:refresh keep the
        # loop going (and :refresh triggers a re-render via the top of the loop).
        break if dispatch(read_input) == :stop
      end
    end

    private

    # Classify each input exactly once, in this exact order:
    #   1. nil (EOF)              -> :stop
    #   2. /quit (case-insens.)   -> :stop
    #   3. /\A\d+\z/ (list index) -> resolve to session id, then attach_to
    #   4. blank                  -> :stay (no-op)
    #   5. else                   -> spawn_session (text line, incl. /foo bar)
    def dispatch(line)
      return :stop if line.nil?

      text = line.chomp
      return :stop if quit?(text)
      return route_index(text) if text =~ /\A\d+\z/
      return :stay if text.strip.empty?

      spawn_session(text)
    end

    def quit?(line)
      line.downcase == "/quit"
    end

    def detach?(line)
      line.downcase == "/detach"
    end

    def stop?(line)
      line.downcase == "/stop"
    end

    # Resolve a numeric list index (1-based) to its session id and attach.
    # Out-of-range indices print a short error and stay in the loop.
    def route_index(text)
      index = Integer(text) - 1
      session = @sessions[index]
      return out_of_range(index) if session.nil?

      attach_to(session.id)
      :stay
    end

    # Print a short out-of-range error for a list index with no session.
    def out_of_range(index)
      $stdout.puts "No session at ##{index + 1} (#{@sessions.size} listed)."
      :stay
    end

    # Spawn a new session from a text line, print its id, and refresh the list.
    def spawn_session(text)
      session = @manager.spawn_session(prompt: text)
      $stdout.puts "Started session #{session.id}"
      :refresh
    end

    # Print the banner and the numbered session list (ordered by created_at).
    # Populates @sessions so dispatch can resolve numeric indices.
    def render_list
      @sessions = @manager.list_sessions
      $stdout.puts BANNER
      $stdout.puts ("=" * BANNER.length)
      $stdout.puts

      if @sessions.empty?
        $stdout.puts EMPTY_HINT
        return
      end

      @sessions.each_with_index do |session, i|
        $stdout.puts format_row(i + 1, session)
      end

      $stdout.puts
      $stdout.puts HELP_HINT
    end

    # One list row: index, status label, short id, last_prompt preview.
    def format_row(index, session)
      "#{index.to_s.rjust(2)}  #{session.status.to_s.ljust(8)} #{short_id(session.id)}  #{preview(session.last_prompt)}"
    end

    def short_id(id)
      id.to_s[0, SHORT_ID_CHARS]
    end

    def preview(text)
      stripped = text.to_s.gsub(/\s+/, " ").strip
      return "—" if stripped.empty?
      return stripped if stripped.length <= PREVIEW_CHARS

      "#{stripped[0, PREVIEW_CHARS]}…"
    end

    # Step-2 integration point. Load (resuming the worker if needed) the
    # session the menu selected, then run the interactive attach loop until the
    # user leaves (/detach, /stop, /quit, EOF) or the session reaches a terminal
    # state. Returns :detach to the menu; never exits the process.
    #
    # Thin renderer only: talks to the duck-typed manager's file-IPC surface,
    # never constructs an Engine. See the plan's Implementation Notes.
    def attach_to(session_id)
      session = @manager.resume_session(session_id, state_dir: @state_dir)
      render_attach_header(session)
      display_history(session_id)

      loop do
        input = read_input
        case classify_attach_input(input)
        when :eof         then return :detach
        when :detach_cmd  then return detach_notice("Detached from session menu.")
        when :quit_cmd    then return detach_notice("Detached — type /quit again from the menu to exit.")
        when :stop_cmd    then return detach_stopped(session_id)
        when :empty       then next
        else
          result = send_and_poll(session_id, input.chomp)
          case result
          when :terminal
            $stdout.puts("Session finished. Detaching to menu.")
            return :detach
          when :timeout
            $stdout.puts("No response within #{POLL_TIMEOUT_SECONDS}s. Detaching to menu.")
            return :detach
          end
          # :ok -> loop back to the prompt
        end
      end
    end

    # Classify one attached-mode input exactly once, in this order:
    #   1. nil (EOF)     -> :eof     -> detach
    #   2. /detach       -> :detach  -> detach (worker keeps running)
    #   3. /stop         -> :stop    -> stop the worker, then detach
    #   4. /quit         -> :quit    -> detach (menu-level exit only)
    #   5. blank         -> :empty   -> no-op, read next line
    #   6. else          -> :message -> send + poll for output
    def classify_attach_input(line)
      return :eof if line.nil?

      text = line.chomp
      return :detach_cmd if detach?(text)
      return :stop_cmd if stop?(text)
      return :quit_cmd if quit?(text)
      return :empty if text.strip.empty?

      :message
    end

    # Short, plain-text header: id, status label, working directory.
    def render_attach_header(session)
      $stdout.puts
      $stdout.puts("Session #{session.id}")
      $stdout.puts("  status:  #{session.status}")
      $stdout.puts("  workdir: #{session.working_directory}")
      $stdout.puts
    end

    # Print the on-disk conversation history by reading the session's output/
    # files. History lives on disk (never on the Session object), so rebuild it
    # here instead of inventing a message list.
    def display_history(session_id)
      responses = @manager.read_responses(session_id, since_time: nil, state_dir: @state_dir)
      return if responses.empty?

      $stdout.puts
      $stdout.puts("Conversation history (from output/):")
      responses.each { |chunk| render_output(chunk) }
    end

    # Send a message via file IPC, then poll output/ for new responses until
    # one arrives, the session goes terminal, or the poll timeout elapses.
    #
    # Captures since_time at send and reads only newer files (matching the
    # worker's mtime filter). Bounded poll: generous timeout, a hard iteration
    # cap, and never a fixed short sleep — a model turn can take many seconds.
    # Returns :ok (back to prompt), :terminal (auto-detach), or :timeout (back
    # to prompt after the deadline with no output).
    def send_and_poll(session_id, message)
      @manager.write_turn_input(session_id, prompt: message, state_dir: @state_dir)
      since_time = Time.now
      deadline = Time.now + POLL_TIMEOUT_SECONDS
      iterations = 0

      loop do
        responses = @manager.read_responses(session_id, since_time: since_time, state_dir: @state_dir)
        responses.each { |chunk| render_output(chunk) }
        return :ok unless responses.empty?
        return :terminal if @manager.wait_for_session(session_id, timeout: 0.5, state_dir: @state_dir)
        return :timeout if Time.now >= deadline || (iterations += 1) >= POLL_ITERATION_CAP

        # wait_for_session above already blocks ~0.5s on a non-terminal check.
      end
    end

    # Render one output chunk through the shared OutputFormatter so wire-format
    # protocol/literal tokens (both the Gemma <|…> control family and the Qwen
    # [[SAMAGOTCHI_LITERAL_*]] call family) are stripped before display. History
    # and live-poll output share this one path. The formatter keeps internal
    # newlines, so multi-line responses stay readable.
    def render_output(chunk)
      text = OutputFormatter.strip(chunk)
      $stdout.puts(text) unless text.empty?
    end

    # Print a detach notice and return to the menu.
    def detach_notice(message)
      $stdout.puts(message)
      :detach
    end

    # Stop the session's worker, confirm it stopped, then detach to the menu.
    def detach_stopped(session_id)
      @manager.stop_session(session_id, state_dir: @state_dir)

      if @manager.wait_for_session(session_id, timeout: 5, state_dir: @state_dir)
        $stdout.puts("Session stopped. Detaching to menu.")
      else
        $stdout.puts("Stopping session… Detaching to menu.")
      end

      :detach
    end

    # Input seam: reads one line from $stdin, or nil on EOF (Ctrl+D). Uses gets
    # (not Reline) so it is trivially stubable in specs and carries no TTY
    # dependency under test. Do not call Reline.readmultiline here.
    def read_input
      $stdin.gets
    end
  end
end
