# frozen_string_literal: true

module Samagotchi
  module Config
    # Tells a worker or chi web when config.yml changes a setting it only
    # reads at its start (Config::Entry#lifecycle: worker_start or web_start,
    # and process_start): "server.port changed — applies after a worker
    # restart". ConfigFile.watch_restart_settings! adds a Watcher;
    # ConfigFile.read_yaml reports each new read of the file (#notify) or a
    # file that doesn't parse (#unreadable), which tells nothing and warns
    # once, instead of every start-only key reading as changed.
    #
    # Thread-safe: the watchers list sits behind one mutex; callbacks run
    # outside it.
    module RestartWatch
      @mutex = Mutex.new
      @watchers = []

      # One process's start-only settings and their start values.
      class Watcher
        LIFECYCLES = {
          worker: %i[worker_start process_start],
          web: %i[web_start process_start]
        }.freeze

        attr_reader :path

        # @param data [Hash, nil] config.yml as the process read it at start
        # @param file_key [Array, nil] that read's [mtime, size]
        def initialize(process:, path:, data:, file_key:, on_change:)
          lifecycles = LIFECYCLES.fetch(process) { raise ArgumentError, "unknown config process #{process.inspect}" }
          raise ArgumentError, "a config change callback is required" unless on_change

          @process = process
          @path = path
          @entries = Config::ENTRIES.select { |entry| entry.config_exposed? && lifecycles.include?(entry.lifecycle) }
          @values = @entries.to_h { |entry| [entry.key, Config.resolve(entry.key, file_data: data, env: {})] }
          @noticed = {}
          @file_key = file_key
          @on_change = on_change
        end

        # [callback, message] for each start-only setting the file read now
        # (+data+, under +file_key+) changes: once per key per new value,
        # none for a value back at its start value. Empty for a read already
        # seen. Caller holds RestartWatch's mutex.
        def changes(file_key, data)
          return [] unless seen!(file_key)

          @entries.filter_map do |entry|
            value = Config.resolve(entry.key, file_data: data, env: {})
            if @values[entry.key] == value
              @noticed.delete(entry.key)
              next
            end
            # Already told for this value: a later edit of another key.
            next if @noticed.key?(entry.key) && @noticed[entry.key] == value

            @noticed[entry.key] = value
            [@on_change, "#{entry.key} changed — applies after #{restart}"]
          end
        end

        # Notes +file_key+ as read; false when it already was. Caller holds
        # RestartWatch's mutex.
        def seen!(file_key)
          return false if @file_key == file_key

          @file_key = file_key
          true
        end

        private

        def restart = @process == :worker ? "a worker restart" : "restarting chi web"
      end

      module_function

      # Adds a Watcher for +process+ (:worker or :web).
      # @return [Proc] unsubscribes
      def watch(process:, path:, data:, file_key:, &on_change)
        watcher = Watcher.new(process: process, path: path, data: data, file_key: file_key, on_change: on_change)
        @mutex.synchronize { @watchers << watcher }
        -> { @mutex.synchronize { @watchers.delete(watcher) } }
      end

      # Tells each watcher of +path+ which of its start-only settings the file
      # read now (+data+, under +file_key+; nil for a missing file) changes.
      def notify(path, file_key, data)
        notices = @mutex.synchronize do
          @watchers.select { |watcher| watcher.path == path }.flat_map { |watcher| watcher.changes(file_key, data) }
        end
        notices.each { |callback, message| callback.call(message) }
      end

      # The file at +path+ (under +file_key+) doesn't parse as a mapping
      # (+problem+ says why): no watcher is told anything (its settings stay
      # compared with the next read that parses), and a process watching it
      # warns once per problem.
      def unreadable(path, file_key, problem)
        watched = @mutex.synchronize do
          @watchers.select { |watcher| watcher.path == path }.each { |watcher| watcher.seen!(file_key) }.any?
        end
        return unless watched

        ConfigFile.warn_once("config: #{path} doesn't parse (#{problem}); " \
                             "start-only settings are checked again when it does")
      end
    end
  end
end
