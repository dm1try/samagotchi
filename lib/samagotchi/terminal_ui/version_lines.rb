# frozen_string_literal: true

require_relative "../installed_versions"
require_relative "../version"

module Samagotchi
  class TerminalUI
    # The line an attaching terminal shows when chi versions differ: the
    # session's worker (its snapshot's chi_version), this terminal (VERSION)
    # and the newest installed. Neither process can reload itself: the worker
    # moves with `chi sessions restart`, the terminal by attaching again.
    module VersionLines
      module_function

      # @param worker [String, nil] the worker's chi_version (nil: a worker
      #   from before it said so; nothing is said then)
      # @param installed [String, nil] InstalledVersions#newest
      # @return [String, nil] one "chi> ..." line, or nil when all is current
      def at_attach(worker:, installed:, session_id:, terminal: VERSION)
        return nil if worker.to_s.empty?

        newest = [installed, terminal].select { |v| Gem::Version.correct?(v.to_s) && !v.to_s.empty? }
                                      .max_by { |v| Gem::Version.new(v) }
        worker_old = InstalledVersions.newer?(newest, worker)
        terminal_old = InstalledVersions.newer?(newest, terminal)
        return nil unless worker_old || terminal_old

        id = session_id.to_s[0, 8]
        restart = "chi sessions restart #{id}"
        attach = "/detach, then chi --attach #{id}"
        if worker_old && terminal_old
          "chi> chi #{newest} is installed; this session's worker runs #{worker} and this terminal #{terminal}. " \
            "#{restart} moves the worker; #{attach} for the terminal."
        elsif worker_old
          "chi> chi #{newest} is installed; this session's worker runs #{worker}. #{restart} moves it there " \
            "(this terminal follows)."
        else
          "chi> chi #{newest} is installed; this terminal runs #{terminal}. #{attach} to use it."
        end
      end

      # After the stream moved to a new worker (a restart).
      def restarted(worker)
        worker.to_s.empty? ? "chi> the session's worker restarted" : "chi> the session's worker restarted on chi #{worker}"
      end
    end
  end
end
