# frozen_string_literal: true

require "json"
require "samagotchi/bridge_client"
require "samagotchi/worker_sidecar"

# A request a spec writes by hand to a real Bridge names the Bridge's secret,
# as BridgeClient does (Bridge#secret_ok?): read from the worker's
# bridge.json, like every client. Include it in the example group.
module BridgeAuth
  # @param where [String] a session folder or its bridge.json
  # @return [Hash{String => String}] the secret's request header
  def bridge_auth(where)
    path = File.directory?(where) ? Samagotchi::WorkerSidecar.path(where) : where
    { Samagotchi::BridgeClient::SECRET_HEADER => JSON.parse(File.read(path)).fetch("secret") }
  end

  # The header line for a request written over a raw socket.
  def bridge_auth_line(where) = bridge_auth(where).map { |name, value| "#{name}: #{value}\r\n" }.join
end
