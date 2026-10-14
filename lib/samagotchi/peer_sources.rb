# frozen_string_literal: true

require_relative "context_sources"

module Samagotchi
  # The attached context sources a loaded peer bundle declared as its
  # peer's answers (chi.peer_source: claude-outbox, codex-outbox), with the
  # peer's name ("Claude"). In-process only: a source is a peer's because
  # the bundle's code says so, never because of what a source file holds,
  # which a pushing process can write. Uninstalling the bundle ends it.
  #
  # A declared name counts only for a pushed source in the session's own
  # location (ContextAbsorber#peer_label): a command or project source of
  # that name is an ordinary one. See docs/context.md (Waking).
  class PeerSources
    # The peer's name, shown inside chi's own framing lines.
    LABEL = /\A[A-Z][A-Za-z ]{0,23}\z/

    def initialize
      @labels = {}
      @bundles = {}
      @lock = Mutex.new
    end

    # Checks +name+ and +label+ before a plugin's registrations commit.
    # @raise [ArgumentError]
    def check!(name, label:, bundle:)
      name = name.to_s
      begin
        ContextSources.check_name!(name)
      rescue ContextSources::Invalid => e
        raise ArgumentError, "peer source: #{e.message}"
      end
      raise ArgumentError, "peer source #{name}: label must match #{LABEL.inspect}" unless label.to_s.match?(LABEL)

      taken = @lock.synchronize { @bundles[name] }
      raise ArgumentError, "peer source #{name} is already declared (#{taken})" if taken && taken != bundle

      name
    end

    # Declares +name+ +label+'s answers (+bundle+: who declared it).
    # @raise [ArgumentError]
    def declare(name, label:, bundle:)
      name = check!(name, label: label, bundle: bundle)
      @lock.synchronize do
        @labels[name] = label.to_s
        @bundles[name] = bundle
      end
      nil
    end

    # @return [String, nil] the peer's name when +name+ is declared
    def label_for(name) = @lock.synchronize { @labels[name.to_s] }

    def names = @lock.synchronize { @labels.keys }
  end
end
