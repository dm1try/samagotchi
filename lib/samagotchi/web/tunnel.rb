# frozen_string_literal: true

require "open3"
require_relative "../config"

module Samagotchi
  module Web
    # `chi web --tunnel PROVIDER`: chi web reached from outside this machine
    # through a provider that gives it an https name and tells it who is
    # asking (Tailscale Serve: docs/configuration.md "Tailscale Serve"). The
    # provider checks what it can before anything changes (#prepare), turns
    # the tunnel on (#up) and off again on exit (#down), never touching what
    # it didn't set. The public_url it makes is this run's, never written to
    # config.yml.
    module Tunnel
      PROVIDERS = %w[tailscale].freeze

      # What a tunnel's #prepare found: the PublicUrl chi web runs with this
      # time, whose login is the owner (:config for web.proxy.owner, :login
      # for this machine's own), whether the serve was already there (a
      # leftover of an earlier run: #down resets it all the same), whether
      # Tailnet Lock is off (a warning line), and the port it forwards to.
      Plan = Data.define(:public_url, :owner_source, :adopted, :lock_off, :port, :dns_name) do
        def target = "http://127.0.0.1:#{port}"
      end

      # Why `chi web --tunnel` won't start: each condition its own class and
      # its own text (callers add only context).
      class Refused < StandardError; end

      # @return [Tailscale] the provider +name+ names
      # @raise [ArgumentError] an unknown name (the flag's list refuses it first)
      def self.for(name, **)
        case name.to_s
        when "tailscale"
          require_relative "tunnel/tailscale"
          Tailscale.new(**)
        else raise ArgumentError, "unknown tunnel #{name} (#{PROVIDERS.join(", ")})"
        end
      end

      # A web.public_url or web.proxy.identity_header setting the tunnel would
      # override for its run.
      class ConfigConflict < Refused
        def initialize(key, value, tunnel_value)
          env = Config::BY_KEY.fetch(key).env_key
          super("#{key} is #{value}, but --tunnel sets it to #{tunnel_value} for this run: remove it from config.yml " \
                "or the environment (#{env}), or drop --tunnel")
        end
      end

      # A chi web already answers on the port: --tunnel starts its own.
      class AlreadyRunning < Refused
        def initialize(port)
          super("chi web already runs on port #{port}, and --tunnel starts its own: stop that one first (Ctrl-C in its " \
                "terminal), or use --port")
        end
      end

      # The provider's command exited with an error.
      class CliFailed < Refused
        def initialize(command, output)
          text = output.to_s.strip
          super("#{command} failed#{text.empty? ? " (no output)" : ": #{text}"}")
        end
      end

      # The provider's command didn't finish in time (stopped): a tailnet
      # where Serve isn't allowed yet prints a consent URL and waits.
      class CliTimeout < Refused
        def initialize(command, seconds, output)
          text = output.to_s.strip
          super("#{command} didn't finish in #{seconds} s and was stopped#{": #{text}" unless text.empty?}" \
                "#{" (if it printed a URL, open it to allow this, then run chi web again)" unless text.empty?}")
        end
      end

      # The provider's command printed something chi can't read: never a
      # guess that could change the wrong thing.
      class UnexpectedOutput < Refused
        def initialize(command)
          super("#{command} printed something chi can't read (a newer version?); nothing was changed")
        end
      end

      # A command run with a deadline: its own process group, both pipes read
      # on threads, the group KILLed past +timeout+ (what it printed so far
      # goes into the Timeout).
      class Runner
        Result = Data.define(:stdout, :stderr, :success) do
          def output = [stdout, stderr].map(&:to_s).reject(&:empty?).join("\n")
        end

        class Timeout < StandardError
          attr_reader :output

          def initialize(output)
            @output = output
            super("timed out")
          end
        end

        # @return [Result]
        # @raise [Timeout]
        # @raise [SystemCallError] the command can't run (ENOENT, EACCES)
        def call(argv, timeout:)
          Open3.popen3(*argv, pgroup: true) do |stdin, out, err, wait|
            stdin.close
            readers = [out, err].map { |io| Thread.new { io.read }.tap { |t| t.report_on_exception = false } }
            unless wait.join(timeout)
              stop(wait.pid)
              readers.each { |reader| reader.join(1) }
              raise Timeout, readers.map { |reader| text(reader) }.reject(&:empty?).join("\n")
            end
            # A process it left behind may hold the pipes: what was read by then.
            readers.each { |reader| reader.join(1) }
            Result.new(stdout: text(readers[0]), stderr: text(readers[1]), success: wait.value.success?)
          end
        end

        private

        def text(reader) = reader.alive? ? "" : reader.value.to_s

        def stop(pid)
          Process.kill("KILL", -pid)
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
