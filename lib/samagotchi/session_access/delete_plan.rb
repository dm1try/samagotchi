# frozen_string_literal: true

require "json"

module Samagotchi
  # Loaded on first use: RunningTasks::Listing.from_wire reads the tasks.
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)

  module SessionAccess
    # A session's delete plan (SessionChain::Delete::Preview, GET
    # /api/sessions/:id/delete_plan) as chi sessions delete --dry-run reads
    # it, on either backend: Local's hash has symbol keys, the route's JSON
    # string keys, and both are read here only (#read). Each choice says
    # what goes, what is stopped first and what stays (docs/sessions.md,
    # Deleting a link).
    module DeletePlan
      # +chained+ false: no +position+, +size+ or +chain+.
      Plan = Data.define(:session_id, :chained, :position, :size, :link, :chain)

      # One choice (the link, or the whole chain): +delete+ the delegates'
      # ids that go with it, +leave+ the ones left (Left), +tasks+ the
      # running tasks its delete would meet (RunningTasks::Listing),
      # +workers+ how many of its sessions have a worker and +turns+ how
      # many of those run a turn, +links+ the links it deletes (1 for a
      # link), +previous_id+ the link its undo brings back (nil: none),
      # +moved+ the sessions that go back with it, +refusal+ (Refusal, nil
      # when it can go now).
      Choice = Data.define(:delete, :leave, :tasks, :workers, :turns, :links, :previous_id, :moved, :refusal)

      # A session the choice leaves: +running+ false for a stopped one left
      # under a running delegate (it stays with it).
      Left = Data.define(:id, :running)

      # Why the delete can't happen now: +reason+ the refusal's code
      # ("scheduled", "owned_by_tui", …), +message+ its words.
      Refusal = Data.define(:reason, :message)

      module_function

      # @param plan [Hash] Preview.call's (symbol keys) or the route's
      #   parsed JSON (string keys)
      # @return [Plan]
      def read(plan)
        json = JSON.parse(JSON.generate(plan))
        Plan.new(session_id: json["session_id"].to_s, chained: json["chained"] == true, position: json["position"],
                 size: json["size"], link: choice(json["link"], links: 1),
                 chain: (choice(json["chain"], links: json.dig("chain", "links").to_i) if json["chain"].is_a?(Hash)))
      end

      def choice(json, links:)
        json = {} unless json.is_a?(Hash)
        delegates = json["delegates"].is_a?(Hash) ? json["delegates"] : {}
        workers, turns = worker_counts(json["worker"])
        Choice.new(delete: Array(delegates["delete"]).map(&:to_s),
                   leave: Array(delegates["leave"]).map { |left| Left.new(id: left["id"].to_s, running: left["running"] == true) },
                   tasks: SessionManager::RunningTasks::Listing.from_wire(json["tasks"]),
                   workers: workers, turns: turns, links: links, previous_id: json["previous_id"],
                   moved: json["moved"].to_i, refusal: refusal(json["refusal"]))
      end

      # A link's "turn" / "idle" / nil, a chain's {idle: n, turn: n}.
      # @return [Array(Integer, Integer)] workers, turns
      def worker_counts(worker)
        case worker
        when "turn" then [1, 1]
        when "idle" then [1, 0]
        when Hash then [worker["idle"].to_i + worker["turn"].to_i, worker["turn"].to_i]
        else [0, 0]
        end
      end

      def refusal(json)
        Refusal.new(reason: json["reason"].to_s, message: json["message"].to_s) if json.is_a?(Hash)
      end
    end
  end
end
