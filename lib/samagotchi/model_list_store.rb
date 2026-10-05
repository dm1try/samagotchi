# frozen_string_literal: true

require "json"
require "fileutils"

require_relative "atomic_file"
require_relative "log"
require_relative "paths"

module Samagotchi
  # The model ids each host last listed, saved in
  # <state dir>/model_lists.json for the processes that spawn a worker but
  # never list a host themselves: `chi send --new --model`, the `delegate`
  # tool and the web refuse an unknown model id up front from it
  # (ModelProfile.check_model!) instead of letting the worker's first turn
  # fail. It is a cache of the hosts' own lists, so it never raises: no
  # file, an unreadable one or bad JSON reads as no list at all. Only a
  # successful listing writes (a host that is down keeps the ids we know),
  # and a list older than TTL_SECONDS is no evidence about the host any
  # more.
  #
  #   { "<host name>" => { "ids" => ["…"], "at" => <epoch seconds> } }
  module ModelListStore
    FILE = "model_lists.json"
    # When a saved list is too old to say what a host serves: a model may
    # have been added or removed since.
    TTL_SECONDS = 7 * 24 * 60 * 60

    # One host's saved list: the ids it listed and when (+at+, epoch
    # seconds).
    Saved = Data.define(:host, :ids, :at) do
      def age(now: Time.now.to_i) = now.to_i - at.to_i

      # Too old to check an id against (ModelProfile.check_model!): a model
      # may have been added or removed since.
      def stale?(now: Time.now.to_i) = age(now: now) > ModelListStore::TTL_SECONDS

      # A host's own list spells its ids, and resolution matches them by
      # case (the registry's model index is downcased): so does this.
      def known?(id) = ids.any? { |known| known.casecmp?(id.to_s.strip) }
    end

    module_function

    # @return [String] <state home>/samagotchi/model_lists.json
    def path(env: ENV)
      File.join(Paths.state_dir(env: env), FILE)
    end

    # Every saved list by host name, the lists as [Saved] (empty without a
    # file, with bad JSON, or with nothing readable in it).
    # @return [Hash{String => Saved}]
    def read(env: ENV)
      all(env: env).each_with_object({}) do |(name, entry), acc|
        list = saved_from(name, entry)
        acc[name] = list if list
      end
    end

    # One host's saved list.
    # @return [Saved, nil] nil without a file, with bad JSON, or with no
    #   entry for the host
    def find(host, env: ENV)
      read(env: env)[host.to_s.strip.downcase]
    end

    # Save the ids +host+ just listed, keeping every other host's entry.
    # Best effort: a store that can't be written never fails the listing
    # that found the ids. An empty list is not saved (it is no evidence the
    # host serves nothing: keep the ids we know).
    # @return [Saved, nil] what was saved, nil when nothing was
    def save(host, ids, at: Time.now.to_i, env: ENV)
      name = host.to_s.strip.downcase
      list = Array(ids).map { |id| id.to_s.strip }.reject(&:empty?).uniq
      return nil if name.empty? || list.empty?

      file = path(env: env)
      FileUtils.mkdir_p(File.dirname(file))
      # Under the lock, so two workers listing a host at once (or two
      # threads of one registry) never drop each other's entries.
      File.open("#{file}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        entries = all(env: env)
        entries[name] = { "ids" => list, "at" => at.to_i }
        AtomicFile.write(file, JSON.pretty_generate(entries) + "\n")
      end
      Saved.new(host: name, ids: list, at: at.to_i)
    rescue StandardError => e
      Log.warn(:model, "model_list_save_failed", host: host.to_s, error: e.class.name, msg: e.message.to_s[0, 200])
      nil
    end

    # The whole file, host names downcased: {name => entry}.
    # @return [Hash]
    def all(env: ENV)
      data = JSON.parse(File.read(path(env: env)))
      return {} unless data.is_a?(Hash)

      data.each_with_object({}) do |(name, entry), acc|
        acc[name.to_s.strip.downcase] = entry if entry.is_a?(Hash)
      end
    rescue StandardError
      {}
    end

    # One +entry+ of the file as a Saved, or nil when it holds no ids or no
    # time.
    def saved_from(name, entry)
      ids = Array(entry["ids"]).map { |id| id.to_s.strip }.reject(&:empty?)
      at = entry["at"].to_i
      return nil if ids.empty? || at <= 0

      Saved.new(host: name, ids: ids, at: at)
    end
    private_class_method :saved_from
  end
end
