# frozen_string_literal: true

require "monitor"
require_relative "../log"

module Samagotchi
  module Plugin
    # A plugin's long-lived thing (a server process, a connection), from
    # chi.service (docs/plugins.md, Services). Its block starts it: on
    # first #value, or at register time with eager: true. What the block
    # returns is #value. Stop callbacks (#on_stop, given inside the block)
    # run when the Engine shuts down (Engine#shutdown), newest first.
    class Service
      # The service was stopped (the Engine shut down): it doesn't start
      # again.
      class Stopped < StandardError; end

      # @return [String] "<bundle>:<name>"
      attr_reader :name

      def initialize(name, &start)
        @name = name
        @start = start
        @mutex = Monitor.new
        @state = :idle
        @value = nil
        @on_stop = []
      end

      # Start it if it hasn't started, and return what its block returned.
      # A block that raises leaves it idle (its on_stop callbacks so far
      # run), so the next use tries again.
      # @raise [Stopped] after #stop
      def value
        @mutex.synchronize do
          raise Stopped, "service #{@name} is stopped" if @state == :stopped
          return @value if @state == :running

          begin
            @value = @start.call(self)
            @state = :running
            Log.info(:plugins, "service_started", service: @name)
            @value
          rescue Exception # rubocop:disable Lint/RescueException -- clean up, then re-raise as is
            run_on_stop
            raise
          end
        end
      end
      alias start value

      # A callback for #stop, given in the start block (close the pipes,
      # kill the process).
      def on_stop(&block)
        raise ArgumentError, "on_stop needs a block" unless block

        @mutex.synchronize { @on_stop << block }
        nil
      end

      # @return [Boolean]
      def running? = @state == :running

      # @return [Symbol] :idle, :running or :stopped
      attr_reader :state

      # Run the stop callbacks (newest first) once; a raise is logged, the
      # rest still run. It never starts again after this.
      def stop
        @mutex.synchronize do
          return if @state == :stopped

          was = @state
          @state = :stopped
          @value = nil
          run_on_stop
          Log.info(:plugins, "service_stopped", service: @name) if was == :running
        end
        nil
      end

      private

      def run_on_stop
        callbacks = @on_stop.reverse
        @on_stop = []
        callbacks.each do |callback|
          callback.call
        rescue StandardError => e
          Log.warn(:plugins, "service_stop_failed", service: @name, error: e.class.name, msg: e.message)
        end
      end
    end

    # An Engine's services, in the order they were registered. #stop_all
    # stops them newest first.
    class Services
      def initialize
        @list = []
        @mutex = Mutex.new
      end

      def add(service)
        @mutex.synchronize { @list << service }
        service
      end

      # @return [Array<Service>]
      def to_a = @mutex.synchronize { @list.dup }

      def stop_all
        to_a.reverse_each(&:stop)
        nil
      end
    end
  end
end
