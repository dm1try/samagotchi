# frozen_string_literal: true

require "samagotchi/web/session_hub"

# A real Web::SessionHub runs the retention sweep on a thread of its own
# (#sweep_if_due, from a full-probe #scan or GET /api/sessions), which
# writes into the hub's state dir (the .last_retention marker, a pruned
# session's files). A spec that removes that dir while the sweep still runs
# fails (Errno::ENOTEMPTY) or races. So every hub a spec builds is stopped
# (SessionHub#stop joins the tick, schedule and sweep threads) before the
# dir goes:
#
#   after do
#     stop_session_hubs
#     FileUtils.remove_entry(state_dir)
#   end
#
# A spec that requires this file gets every hub it builds recorded, wherever
# it was built (a let, an example, an App's hub: argument). The config-level
# after hook below stops any left over, so no thread outlives its example;
# it runs after the spec's own after hooks, so it does not replace the call
# above where a spec removes the dir itself.
module SessionHubs
  LOCK = Mutex.new

  # Records each hub as it is built.
  module Tracking
    def initialize(...)
      super
      SessionHubs.record(self)
    end
  end

  def self.record(hub)
    LOCK.synchronize { (@built ||= []) << hub }
  end

  # Stops (and forgets) every hub built since the last call.
  def self.stop_all
    hubs = LOCK.synchronize do
      built = @built || []
      @built = []
      built
    end
    hubs.each(&:stop)
    nil
  end

  def stop_session_hubs = SessionHubs.stop_all
end

Samagotchi::Web::SessionHub.prepend(SessionHubs::Tracking)

RSpec.configure do |config|
  config.include SessionHubs
  config.after { SessionHubs.stop_all }
end
