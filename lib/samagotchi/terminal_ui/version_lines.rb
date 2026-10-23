# frozen_string_literal: true

require_relative "../installed_versions"
require_relative "../version"
require_relative "../chi_invocation"

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
      # @param via [ChiInvocation] how the commands in it are spelled
      # @return [String, nil] one "chi> ..." line, or nil when all is current
      def at_attach(worker:, installed:, session_id:, terminal: VERSION, via: ChiInvocation::HERE)
        return nil if worker.to_s.empty?
        return across_machines(worker: worker, installed: installed, session_id: session_id, terminal: terminal, via: via) if via.remote?

        newest = [installed, terminal].select { |v| Gem::Version.correct?(v.to_s) && !v.to_s.empty? }
                                      .max_by { |v| Gem::Version.new(v) }
        worker_old = InstalledVersions.newer?(newest, worker)
        terminal_old = InstalledVersions.newer?(newest, terminal)
        return nil unless worker_old || terminal_old

        id = session_id.to_s[0, 8]
        restart = via.command("sessions restart #{id}")
        attach = "/detach, then #{via.attach(id)}"
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

      # A remote attach (P4-D10): the worker and +installed+ are that
      # machine's, the terminal this one's, so each is advised where it
      # runs: the worker older than that machine's newest moves with chi
      # --remote NAME sessions restart; this terminal older than the newer
      # of the two updates here.
      # @return [String, nil]
      def across_machines(worker:, installed:, session_id:, terminal:, via:)
        there = [installed, worker].select { |v| Gem::Version.correct?(v.to_s) && !v.to_s.empty? }
                                   .max_by { |v| Gem::Version.new(v) }
        worker_old = InstalledVersions.newer?(installed, worker)
        terminal_old = InstalledVersions.newer?(there, terminal)
        return nil unless worker_old || terminal_old

        lines = []
        if worker_old
          lines << "the session's worker runs chi #{worker}; #{via.remote} has #{installed} installed: " \
                   "#{via.command("sessions restart #{session_id.to_s[0, 8]}")}"
        end
        lines << "#{worker_old ? "This" : "this"} terminal runs chi #{terminal} (#{via.remote} has #{there}): chi update here" if terminal_old
        "chi> #{lines.join(". ")}"
      end

      # After the stream moved to a new worker (a restart).
      def restarted(worker)
        worker.to_s.empty? ? "chi> the session's worker restarted" : "chi> the session's worker restarted on chi #{worker}"
      end
    end
  end
end
