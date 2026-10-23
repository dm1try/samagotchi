# frozen_string_literal: true

require "stringio"
require_relative "../session_access"

module Samagotchi
  class TerminalUI
    # The attached TUI's /share and /participants: chi share for the
    # attached session, through the same SessionAccess (this machine's, or
    # the remote's under chi --remote), with its words and its one message
    # per condition. Errors are led by the command as typed.
    #   /share NAME [--agent] [--expires 3d] [--cap 2]   chi share ID --name NAME …
    #   /participants                                    chi share ls ID
    #   /participants revoke [P]                         chi share revoke ID [P]
    #   /participants cap P DOLLARS                      chi share cap ID P DOLLARS
    class ParticipantCommands
      SHARE_USAGE = "usage: /share NAME [--agent] [--expires 3d] [--cap 2]: invite NAME to review this session"
      PARTICIPANTS_USAGE = "usage: /participants [revoke [PARTICIPANT] | cap PARTICIPANT DOLLARS]"

      # @param access [SessionAccess::Local, SessionAccess::Remote]
      # @param session_id [String]
      # @param tty [Boolean] print the invite's QR code
      def initialize(access:, session_id:, tty:)
        @access = access
        @session_id = session_id
        @tty = tty
      end

      # @param line [String] "/share …" or "/participants …"
      # @return [String] what to show
      def run(line)
        command, *words = line.strip.split
        command.casecmp?("/share") ? share(words) : participants(words)
      end

      private

      def share(words)
        name_words = words.take_while { |word| !word.start_with?("--") }
        return SHARE_USAGE if name_words.empty?

        share_command([@session_id, "--name", name_words.join(" "), *words.drop(name_words.size)], "/share")
      end

      def participants(words)
        sub, *rest = words
        case sub&.downcase
        when nil then share_command(["ls", @session_id], "/participants")
        when "revoke" then share_command(["revoke", @session_id, *rest], "/participants revoke")
        when "cap" then share_command(["cap", @session_id, *rest], "/participants cap")
        else PARTICIPANTS_USAGE
        end
      end

      def share_command(argv, name)
        require_relative "../share_command"
        out = StringIO.new
        ShareCommand.new(argv, stdin: StringIO.new, stdout: out, stderr: out, access: @access, tty: @tty, name: name).run
        out.string.chomp
      rescue SessionAccess::RemoteFailed => e
        "#{name}: #{e.message}"
      end
    end
  end
end
