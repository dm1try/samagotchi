# frozen_string_literal: true

require_relative "peer_mailbox"

module Samagotchi
  # The peers a loaded bundle declared (chi.peer NAME), in this worker's
  # process: the one answer to "is this a peer's message", which decides
  # that a mailbox message becomes a peer's note and may wake chi
  # (WorkerInbound#absorb_mail). The CLI and chi web decide no behaviour:
  # for them "paired" is a link.json (PeerMailbox). A name no loaded bundle
  # declared gets a refused receipt (undeclared). Uninstalling the bundle
  # ends it. See docs/internals/peers.md.
  class PeerRegistry
    def initialize
      @bundles = {}
      @lock = Mutex.new
    end

    # Checks +name+ before a plugin's registrations commit.
    # @return [String] +name+
    # @raise [ArgumentError]
    def check!(name, bundle:)
      name = name.to_s
      raise ArgumentError, "peer: #{PeerMailbox.name_problem(name)}" unless PeerMailbox.valid_name?(name)

      taken = @lock.synchronize { @bundles[name] }
      raise ArgumentError, "peer #{name} is already declared (#{taken})" if taken && taken != bundle

      name
    end

    # Declares peer +name+ (+bundle+: who declared it).
    # @raise [ArgumentError]
    def declare(name, bundle:)
      name = check!(name, bundle: bundle)
      @lock.synchronize { @bundles[name] = bundle }
      nil
    end

    def declared?(name) = @lock.synchronize { @bundles.key?(name.to_s) }

    def names = @lock.synchronize { @bundles.keys }
  end
end
