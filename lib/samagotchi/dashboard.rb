
# frozen_string_literal: true

require "samagotchi/session_manager"

module Samagotchi
  # Dashboard — CLI menu for managing background sessions.
  class Dashboard
    QUIT_COMMAND = "/quit"
    DETACH_COMMAND = "/detach"
    STOP_COMMAND = "/stop"
    CONTINUE_PROMPT = "/continue"

    def initialize
      @sessions = []
    end

    # Main dashboard loop.
    def run
      loop do
        render_menu
        input = $stdin.gets
        break unless input

        input = input.chomp.strip

        case input
        when QUIT_COMMAND
          break
        when /\A\d+\z/
          index = input.to_i - 1
          if index >= 0 && index < @sessions.length
            attach_to_session(@sessions[index])
          else
            puts "Invalid selection."
          end
        when ""
          # empty input, re-render
          next
        else
          spawn_new_session(input)
        end
      end
      puts "Goodbye!"
    end

    private

    def render_menu
      @sessions = SessionManager.list_sessions
      $stdout.puts "\n" + "─" * 35
      $stdout.puts " Chi Dashboard"
      $stdout.puts "─" * 35

      if @sessions.empty?
        $stdout.puts " No sessions."
      else
        $stdout.puts " Sessions:"
        @sessions.each_with_index do |session, i|
          preview = session.last_prompt.to_s[0, 35]
          preview = "#{preview}..." if session.last_prompt.to_s.length > 35
          $stdout.puts "  #{i + 1}. [#{session.status}] #{session.id[0, 8]}  #{preview}"
        end
      end

      $stdout.puts "─" * 35
      $stdout.puts " Enter number to attach,"
      $stdout.puts "   type a prompt for new session,"
      $stdout.puts "   #{QUIT_COMMAND} to exit"
      $stdout.print "> "
      $stdout.flush
    end

    def spawn_new_session(prompt)
      puts "Starting new session..."
      session = SessionManager.spawn_session(
        prompt: prompt,
        mode: "assist",
        working_directory: Dir.pwd
      )
      puts "Session #{session.id} started with: #{prompt[0, 40]}"
    end

    def attach_to_session(session)
      loop do
        render_attach_menu(session)
        input = $stdin.gets
        break unless input

        input = input.chomp.strip

        case input
        when DETACH_COMMAND
          break
        when STOP_COMMAND
          SessionManager.stop_session(session.id)
          puts "Session stopped."
          break
        when CONTINUE_PROMPT
          # Reload session to show latest status
          session = Session.load(session.id)
          show_session_status(session)
          next
        when ""
          next
        else
          send_message(session, input)
        end
      end
    end

    def render_attach_menu(session)
      # Reload session data
      begin
        session = Session.load(session.id)
      rescue ArgumentError
        puts "Session no longer exists."
        return
      end

      $stdout.puts "\n" + "─" * 35
      $stdout.puts " Attached: #{session.id[0, 12]}"
      $stdout.puts " Status: #{session.status}"
      $stdout.puts " Messages: #{session.messages.length}"
      $stdout.puts "─" * 35
      $stdout.puts " Type message to send,"
      $stdout.puts "   #{DETACH_COMMAND} to detach,"
      $stdout.puts "   #{STOP_COMMAND} to stop session,"
      $stdout.puts "   #{CONTINUE_PROMPT} to refresh status"
      $stdout.print "> "
      $stdout.flush
    end

    def show_session_status(session)
      puts "Status: #{session.status}"
      puts "Messages: #{session.messages.length}"
      puts "Last prompt: #{session.last_prompt.to_s[0, 40]}"
    end

    def send_message(session, message)
      responses = SessionManager.attach_session(session.id, message: message)

      if responses.any?
        responses.each { |r| puts "→ #{r}" }
      else
        puts "Message sent. (No response yet)"
      end
    end
  end
end

