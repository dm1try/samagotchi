# frozen_string_literal: true

require "json"
require_relative "../tunnel"
require_relative "../public_url"
require_relative "../../session"

module Samagotchi
  module Web
    module Tunnel
      # `chi web --tunnel tailscale`: Tailscale Serve on this machine's
      # tailnet name, port 443 → chi web's 127.0.0.1 port, never Funnel.
      # The identity is the Tailscale login Serve sends (Tailscale-User-Login);
      # the owner is web.proxy.owner, else this machine's own login.
      #
      # Serve's other ports are never touched, and on 443 only exactly what
      # this provider sets (one handler / → http://127.0.0.1:<port>, no
      # Funnel) is adopted or turned off: anything else there is refused at
      # start and left alone at exit.
      class Tailscale
        # The CLI to run, before PATH: every spec that runs it sets this to a
        # fake.
        ENV_CLI = "SAMAGOTCHI_TAILSCALE_CLI"
        # The macOS app's own CLI, when there is no tailscale on PATH (never
        # in a test run).
        APP_CLI = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        IDENTITY_HEADER = "Tailscale-User-Login"
        STATUS_TIMEOUT = 5
        SERVE_TIMEOUT = 15
        LOCK_DOCS = "https://tailscale.com/kb/1226/tailnet-lock"

        # No tailscale to run.
        class CliMissing < Refused
          def initialize
            super("tailscale isn't installed: no tailscale on PATH or at #{APP_CLI} (install it from tailscale.com, " \
                  "or set #{ENV_CLI} to its path)")
          end
        end

        # SAMAGOTCHI_TAILSCALE_CLI names something that can't run.
        class CliOverrideMissing < Refused
          def initialize(path)
            super("#{ENV_CLI} is #{path}, which isn't an executable file")
          end
        end

        # Tailscale is installed but not connected (BackendState).
        class NotRunning < Refused
          def initialize(state)
            super("Tailscale isn't connected (#{state}): open the Tailscale app and sign in, then run this again")
          end
        end

        # No MagicDNS name for this machine.
        class NoDnsName < Refused
          def initialize
            super("this machine has no tailnet name: turn on MagicDNS in the Tailscale admin console (DNS)")
          end
        end

        # HTTPS certificates are off (no CertDomains for the name).
        class NoHttps < Refused
          def initialize(name)
            super("HTTPS certificates are off for this tailnet (none for #{name}): turn them on in the Tailscale admin " \
                  "console (DNS); rename this machine first, certificate names go into a public log")
          end
        end

        # A tagged machine's UserID isn't a person: no owner by default.
        class TaggedOwner < Refused
          def initialize(tags)
            super("this machine is tagged (#{tags.join(", ")}), so its Tailscale login isn't a person's: set " \
                  "web.proxy.owner to your Tailscale login")
          end
        end

        # Something other than this provider's one handler serves 443.
        class ServeInUse < Refused
          def initialize(what)
            super("Tailscale Serve already serves port 443 here (#{what}), and chi web won't change it: turn it off " \
                  "with tailscale serve --https=443 off, or use it as it is without --tunnel")
          end
        end

        # Funnel (the public internet) is on for 443.
        class Funnel < Refused
          def initialize(name)
            super("Tailscale Funnel is on for #{name} (the public internet), and chi web never runs behind Funnel: " \
                  "turn it off first (tailscale funnel status shows it)")
          end
        end

        # @param env [Hash] ENV: SAMAGOTCHI_TAILSCALE_CLI, PATH, the test-run flags
        # @param app_cli [String] the app bundle's CLI (a spec's own path)
        # @param runner [#call] (argv, timeout:) → Runner::Result
        def initialize(env: ENV, app_cli: APP_CLI, runner: Runner.new)
          @env = env
          @app_cli = app_cli
          @runner = runner
        end

        # The tailscale command: SAMAGOTCHI_TAILSCALE_CLI, else tailscale on
        # PATH, else the macOS app's CLI (not in a test run).
        # @raise [CliMissing, CliOverrideMissing]
        def cli
          @cli ||= lookup
        end

        # Everything checked before anything changes: connected, the name
        # and its certificate, the owner, config conflicts, what Serve has
        # on 443, Tailnet Lock.
        # @param config_owner [String, nil] web.proxy.owner
        # @param config_public_url [String, nil] web.public_url
        # @param config_identity_header [String, nil] web.proxy.identity_header
        # @return [Plan]
        # @raise [Refused]
        def prepare(port:, config_owner: nil, config_public_url: nil, config_identity_header: nil)
          status = json(%w[status --json])
          dns_name = connected_name(status)
          origin = "https://#{dns_name}"
          check_config(origin, config_public_url, config_identity_header)
          owner, owner_source = owner_for(status, config_owner)
          adopted = classify(json(%w[serve status --json]), dns_name, port) == :ours
          public_url = PublicUrl.from_config(url: origin, identity_header: IDENTITY_HEADER, owner: owner)
          Plan.new(public_url: public_url, owner_source: owner_source, adopted: adopted, lock_off: lock_off?,
                   port: port, dns_name: dns_name)
        end

        # What Serve has on 443: :none, :ours (exactly one handler / →
        # http://127.0.0.1:<port>, no Funnel), or a ServeInUse / Funnel.
        # Other ports are not looked at.
        # @raise [ServeInUse, Funnel, UnexpectedOutput]
        def classify(serve, dns_name, port)
          raise UnexpectedOutput, command(%w[serve status --json]) unless serve.is_a?(Hash)

          funnel = hash(serve["AllowFunnel"]).find { |key, on| on && https_key?(key) }
          raise Funnel, funnel.first if funnel

          tcp = hash(serve["TCP"])["443"]
          web = hash(serve["Web"]).select { |key, _| https_key?(key) }
          return :none if tcp.nil? && web.empty?
          return :ours if ours?(tcp, web, dns_name, port)

          raise ServeInUse, describe(tcp, web)
        end

        private

        def lookup
          override = @env[ENV_CLI].to_s.strip
          unless override.empty?
            return override if executable?(override)

            raise CliOverrideMissing, override
          end
          on_path = @env["PATH"].to_s.split(File::PATH_SEPARATOR).reject(&:empty?)
                                .map { |dir| File.join(dir, "tailscale") }.find { |path| executable?(path) }
          return on_path if on_path
          return @app_cli if !Session.test_session_env?(env: @env) && executable?(@app_cli)

          raise CliMissing
        end

        def executable?(path) = File.file?(path) && File.executable?(path)

        def connected_name(status)
          raise UnexpectedOutput, command(%w[status --json]) unless status.is_a?(Hash)

          state = status["BackendState"].to_s
          raise NotRunning, (state.empty? ? "no state" : state) unless state == "Running"

          name = hash(status["Self"])["DNSName"].to_s.strip.downcase.delete_suffix(".")
          raise NoDnsName if name.empty?
          raise NoHttps, name unless Array(status["CertDomains"]).any? { |domain| domain.to_s.casecmp?(name) }

          name
        end

        def check_config(origin, config_public_url, config_identity_header)
          unless blank?(config_public_url) || configured_origin(config_public_url) == origin
            raise ConfigConflict.new("web.public_url", config_public_url.to_s.strip, origin)
          end
          return if blank?(config_identity_header) || config_identity_header.to_s.strip.casecmp?(IDENTITY_HEADER)

          raise ConfigConflict.new("web.proxy.identity_header", config_identity_header.to_s.strip, IDENTITY_HEADER)
        end

        def configured_origin(url)
          PublicUrl.from_config(url: url)&.origin
        rescue PublicUrl::Invalid
          nil
        end

        # [login, :config | :login]
        def owner_for(status, config_owner)
          return [config_owner.to_s.strip, :config] unless blank?(config_owner)

          me = hash(status["Self"])
          tags = Array(me["Tags"])
          raise TaggedOwner, tags.map(&:to_s) unless tags.empty?

          login = hash(hash(status["User"])[me["UserID"].to_s])["LoginName"].to_s.strip
          raise UnexpectedOutput, command(%w[status --json]) if login.empty?

          [login, :login]
        end

        def ours?(tcp, web, dns_name, port)
          handlers = { "Handlers" => { "/" => { "Proxy" => "http://127.0.0.1:#{port}" } } }
          tcp == { "HTTPS" => true } && web.size == 1 && web.keys.first.casecmp?("#{dns_name}:443") &&
            web.values.first == handlers
        end

        def describe(tcp, web)
          parts = web.values.flat_map do |entry|
            hash(hash(entry)["Handlers"]).map { |path, handler| "#{path} → #{handler_target(handler)}" }
          end
          forward = hash(tcp)["TCPForward"]
          parts << "TCP → #{forward}" if forward
          parts.empty? ? "a configuration chi web didn't make" : parts.join(", ")
        end

        def handler_target(handler)
          handler = hash(handler)
          handler["Proxy"] || (handler["Path"] && "files #{handler["Path"]}") || (handler.key?("Text") && "text") ||
            handler.keys.join("/")
        end

        def https_key?(key) = key.to_s.end_with?(":443")

        # Tailnet Lock is off (Enabled false); a failure says nothing.
        def lock_off?
          json(%w[lock status --json]).then { |lock| lock.is_a?(Hash) && lock["Enabled"] == false }
        rescue Refused
          false
        end

        def json(args)
          result = run(args, timeout: STATUS_TIMEOUT)
          raise CliFailed.new(command(args), result.output) unless result.success

          JSON.parse(result.stdout)
        rescue JSON::ParserError
          raise UnexpectedOutput, command(args)
        end

        def run(args, timeout:)
          @runner.call([cli, *args], timeout: timeout)
        rescue Runner::Timeout => e
          raise CliTimeout.new(command(args), timeout, e.output)
        rescue SystemCallError => e
          raise CliFailed.new(command(args), e.message)
        end

        def command(args) = ["tailscale", *args].join(" ")
        def hash(value) = value.is_a?(Hash) ? value : {}
        def blank?(value) = value.to_s.strip.empty?
      end
    end
  end
end
