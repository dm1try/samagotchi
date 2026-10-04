# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "rbconfig"
require "rubygems/package"
require_relative "version"

module Samagotchi
  # The gem part of `chi update`: the newest samagotchi on rubygems, and a
  # `gem install` of it through this Ruby's own gem command (the real
  # interpreter's bindir, not a shim: the same under mise, rbenv and asdf).
  #
  # SAMAGOTCHI_UPDATE_GEM_FILE=<path to a .gem> (hidden, for smokes) makes that
  # file the newest version and installs it instead.
  class GemUpdate
    class Error < StandardError
    end

    LATEST_URL = URI("https://rubygems.org/api/v1/versions/samagotchi/latest.json")
    # Not SAMAGOTCHI_UPDATE_GEM: that is the env form of config update.gem.
    LOCAL_ENV = "SAMAGOTCHI_UPDATE_GEM_FILE"
    TIMEOUT = 5

    # source is what `gem install` takes: the gem's name, or a .gem file.
    Latest = Struct.new(:version, :source, keyword_init: true)

    # Runs a command without a shell; [output, success].
    class Runner
      def run(argv)
        output, status = Open3.capture2e(*argv)
        [output, status.success?]
      rescue SystemCallError => e
        [e.message, false]
      end
    end

    # @param fetcher [#call, nil] → the latest.json body (specs)
    def initialize(env: ENV, fetcher: nil, runner: Runner.new, gem_bin: File.join(RbConfig::CONFIG["bindir"], "gem"))
      @env = env
      @fetcher = fetcher || method(:fetch)
      @runner = runner
      @gem_bin = gem_bin
    end

    # @return [Latest]
    # @raise [Error] when it can't be found out (offline, a bad answer)
    def latest
      local = @env[LOCAL_ENV].to_s
      return Latest.new(version: Gem::Package.new(local).spec.version.to_s, source: local) unless local.empty?

      version = JSON.parse(@fetcher.call.to_s)["version"].to_s
      raise Error, "rubygems.org answered without a version" if version.empty? || !Gem::Version.correct?(version)

      Latest.new(version: version, source: "samagotchi")
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "#{e.class}: #{e.message}".lines.first.strip
    end

    def newer?(latest, current = VERSION)
      Gem::Version.new(latest.version) > Gem::Version.new(current)
    end

    def install_argv(latest)
      argv = [@gem_bin, "install", latest.source, "--no-document"]
      latest.source == "samagotchi" ? argv + ["-v", latest.version] : argv
    end

    # @return [Array(String, Boolean)] gem's output, success
    def install(latest)
      @runner.run(install_argv(latest))
    end

    private

    def fetch
      Net::HTTP.start(LATEST_URL.host, LATEST_URL.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        request = Net::HTTP::Get.new(LATEST_URL)
        request["User-Agent"] = USER_AGENT
        response = http.request(request)
        raise Error, "rubygems.org answered #{response.code}" unless response.code == "200"

        response.body
      end
    end
  end
end
