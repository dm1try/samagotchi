# frozen_string_literal: true

require "samagotchi/worker_link"
require "samagotchi/worker_sidecar"

# WorkerLink outcomes for stubs: a spec that stubs WorkerLink.resolve or
# .await (or chi web's #worker_link) returns one of these where it used to
# return a sidecar or a client. Include it in the example group.
module WorkerLinks
  # A Live outcome for +sidecar+. With +client+ (a spec's BridgeClient
  # double), a verified double of one whose #client is that client, so a
  # caller that makes the client from the link gets the spec's own.
  # @param sidecar [WorkerSidecar, Hash, nil] a sidecar, or its fields
  # @return [Samagotchi::WorkerLink::Live]
  def live_link(sidecar = nil, client: nil)
    sidecar = Samagotchi::WorkerSidecar.new(**sidecar) if sidecar.is_a?(Hash)
    return Samagotchi::WorkerLink::Live.new(sidecar: sidecar) unless client

    instance_double(Samagotchi::WorkerLink::Live, live?: true, worker_owned?: true, sidecar: sidecar, client: client)
  end

  # @return [Samagotchi::WorkerLink::None]
  def none_link = Samagotchi::WorkerLink::None.new
end
