# frozen_string_literal: true

require "samagotchi/session_manager"

module Samagotchi
  # Dashboard — a thin menu loop for managing background sessions.
  #
  # Step 1 (this file): render the numbered session list, spawn a new session
  # from a typed line, route numeric lines to the #attach_to seam (Step 2), and
  # support /quit to exit.
  #
  # The dashboard is intentionally thin. It never constructs an Engine, spawns
  # an inline agent loop, or reaches into TerminalUI. It only talks to a
  # duck-typed manager object (responding to #list_sessions / #spawn_session),
  # which keeps the menu loop fork-free in specs. Attaching in Step 2 will keep
  # using file-IPC, never an inline Engine.
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

    # Default manager: the SessionManager class responds to its own class
    # methods (list_sessions / spawn_session), so injection is duck-typed.
    def initialize(manager: nil)
      @manager = manager || Samagotchi::SessionManager
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

    # Step 1 placeholder. This is the explicit integration point Step 2 fills
    # in with real attach (poll output/, send messages, /detach, /stop).
    def attach_to(_session_id)
      $stdout.puts(<<~MSG.strip)
        Attach is coming soon (Step 2).

        In Step 2 this method will poll the session's output directory, let you
        send messages, and support /detach and /stop. The number route above is
        wired so Step 2 can drop in the real implementation here.
      MSG
    end

    # Input seam: reads one line from $stdin, or nil on EOF (Ctrl+D). Uses gets
    # (not Reline) so it is trivially stubable in specs and carries no TTY
    # dependency under test. Do not call Reline.readmultiline here.
    def read_input
      $stdin.gets
    end
  end
end
