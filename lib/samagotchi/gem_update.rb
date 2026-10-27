# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "rbconfig"
require "rubygems/package"
require "time"
require_relative "version"
require_relative "redacted_inspect"

module Samagotchi
  # The gem part of `chi update`: the newest samagotchi on rubygems, and a
  # `gem install` of it through this Ruby's own gem command (the real
  # interpreter's bindir, not a shim: the same under mise, rbenv and asdf).
  #
  # SAMAGOTCHI_UPDATE_GEM_FILE=<path to a .gem> (hidden, for smokes) makes that
  # file the newest version and installs it instead.
  class GemUpdate
    include RedactedInspect

    class Error < StandardError
    end

    LATEST_URL = URI("https://rubygems.org/api/v1/versions/samagotchi/latest.json")
    RELEASES_URL = URI("https://rubygems.org/api/v1/versions/samagotchi.json")
    # Not SAMAGOTCHI_UPDATE_GEM: that is the env form of config update.gem.
    LOCAL_ENV = "SAMAGOTCHI_UPDATE_GEM_FILE"
    TIMEOUT = 5

    # source is what `gem install` takes: the gem's name, or a .gem file.
    Latest = Struct.new(:version, :source, keyword_init: true)
    Release = Data.define(:version, :created_at, :prerelease)

    # Runs a command without a shell; [output, success].
    class Runner
      def run(argv)
        output, status = Open3.capture2e(*argv)
        [output, status.success?]
      rescue SystemCallError => e
        [e.message, false]
      end
    end

    # This Ruby's own gem command (chi bootstrap installs commonmarker with
    # it too).
    def self.gem_bin = File.join(RbConfig::CONFIG["bindir"], "gem")

    # @param fetcher [#call, nil] → the latest.json body (specs)
    def initialize(env: ENV, fetcher: nil, runner: Runner.new, gem_bin: GemUpdate.gem_bin)
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

      version = JSON.parse(fetch_body(LATEST_URL).to_s)["version"].to_s
      raise Error, "rubygems.org answered without a version" if version.empty? || !Gem::Version.correct?(version)

      Latest.new(version: version, source: "samagotchi")
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "#{e.class}: #{e.message}".lines.first.strip
    end

    # @return [Array<Release>] rubygems releases, or the one local smoke gem
    def releases
      local = @env[LOCAL_ENV].to_s
      return [local_release(local)] unless local.empty?

      records = JSON.parse(fetch_body(RELEASES_URL).to_s)
      raise Error, "rubygems.org answered without a releases list" unless records.is_a?(Array)

      records.map do |record|
        version = record["number"].to_s
        created_at = record["created_at"].to_s
        unless Gem::Version.correct?(version) && !created_at.empty? && [true, false].include?(record["prerelease"])
          raise Error, "rubygems.org answered with an invalid release"
        end

        Release.new(version: version, created_at: Time.iso8601(created_at), prerelease: record["prerelease"])
      end
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

    def local_release(path)
      version = Gem::Package.new(path).spec.version
      Release.new(version: version.to_s, created_at: File.mtime(path), prerelease: version.prerelease?)
    end

    def fetch_body(url)
      return @fetcher.call if @fetcher.arity.zero?

      @fetcher.call(url)
    end

    def fetch(url = LATEST_URL)
      Net::HTTP.start(url.host, url.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        request = Net::HTTP::Get.new(url)
        request["User-Agent"] = USER_AGENT
        response = http.request(request)
        raise Error, "rubygems.org answered #{response.code}" unless response.code == "200"

        response.body
      end
    end
  end
end
