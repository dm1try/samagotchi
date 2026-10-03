# frozen_string_literal: true

require_relative "installed_gem"
require_relative "version"

module Samagotchi
  # The newest chi on this machine, which a long-lived process (chi web, an
  # attaching TUI) compares with its own VERSION to say "chi X is installed;
  # restart". Run from an installed gem: the highest samagotchi-<v>.gemspec
  # in RubyGems' specification dirs, matching the `>= 0.a` a new worker
  # activates (prereleases count). Run from a source checkout: the VERSION
  # in lib/samagotchi/version.rb on disk now (a `git pull` moves it).
  #
  # Cheap enough to poll: each dir is listed again only when its mtime
  # changed, version.rb is re-read only when its mtime did, and nothing
  # calls Gem::Specification.reset (that would disturb the running process).
  #
  # SAMAGOTCHI_INSTALLED_VERSION=<v> (hidden, for smokes and e2e) answers
  # <v> instead.
  class InstalledVersions
    ENV_KEY = "SAMAGOTCHI_INSTALLED_VERSION"
    GEMSPEC = /\Asamagotchi-(#{Gem::Version::VERSION_PATTERN})\.gemspec\z/
    VERSION_LINE = /^\s*VERSION\s*=\s*["']([^"']+)["']/
    REQUIREMENT = Gem::Requirement.new(">= 0.a")

    # @param gem_spec [Gem::Specification, nil] the installed gem this code
    #   runs from (nil: a source checkout)
    # @param dirs [#call] → the specification dirs to list
    # @param version_file [String] a checkout's version.rb
    def initialize(env: ENV, gem_spec: InstalledGem.spec, dirs: -> { Gem::Specification.dirs },
                   version_file: File.join(InstalledGem::ROOT, "lib", "samagotchi", "version.rb"))
      @env = env
      @gem_spec = gem_spec
      @dirs = dirs
      @version_file = version_file
      @dir_cache = {}
      @file_cache = nil
      @mutex = Mutex.new
    end

    # @return [String, nil] the newest installed version, or nil when none
    #   could be found out
    def newest
      seam = @env[ENV_KEY].to_s
      return seam unless seam.empty?

      @mutex.synchronize { @gem_spec ? newest_gem : checkout_version }
    end

    # Whether +installed+ is a newer version than +running+.
    def self.newer?(installed, running = VERSION)
      return false if installed.to_s.empty? || !Gem::Version.correct?(installed) || !Gem::Version.correct?(running)

      Gem::Version.new(installed) > Gem::Version.new(running)
    end

    private

    def newest_gem
      @dirs.call.filter_map { |dir| dir_newest(dir) }.max&.to_s
    end

    def dir_newest(dir)
      mtime = File.mtime(dir)
      cached = @dir_cache[dir]
      return cached[1] if cached && cached[0] == mtime

      best = Dir.children(dir).filter_map { |name| GEMSPEC.match(name)&.[](1) }
                .select { |v| Gem::Version.correct?(v) }
                .map { |v| Gem::Version.new(v) }
                .select { |v| REQUIREMENT.satisfied_by?(v) }.max
      @dir_cache[dir] = [mtime, best]
      best
    rescue SystemCallError
      @dir_cache.delete(dir)
      nil
    end

    def checkout_version
      mtime = File.mtime(@version_file)
      return @file_cache[1] if @file_cache && @file_cache[0] == mtime

      version = File.read(@version_file)[VERSION_LINE, 1]
      version = nil unless version && Gem::Version.correct?(version)
      @file_cache = [mtime, version]
      version
    rescue SystemCallError
      nil
    end
  end
end
