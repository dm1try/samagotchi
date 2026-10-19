# frozen_string_literal: true

module Samagotchi
  # Whether this code runs as an installed gem, and where that gem's
  # RubyGems wrapper (`chi` on the PATH) is. A source checkout (bin/chi, or
  # bundle exec with the Gemfile's `gemspec`) is not an installed gem.
  module InstalledGem
    ROOT = File.expand_path("../..", __dir__)

    module_function

    # The installed spec RubyGems activated (the `chi` wrapper does), from a
    # specifications/ dir, when its directory is this code's; else nil.
    def spec(gem_dir = ROOT)
      spec = Gem.loaded_specs["samagotchi"]
      return nil unless spec&.loaded_from && File.basename(File.dirname(spec.loaded_from)) == "specifications"

      real_path(spec.full_gem_path) == real_path(gem_dir) ? spec : nil
    end

    # The wrapper RubyGems wrote for the gem's `chi` (GEM_HOME/bin/chi and
    # the like): it activates the newest installed samagotchi, so a path to
    # it outlives upgrades and `gem cleanup`, unlike <gem dir>/bin/chi.
    # nil when the wrapper isn't there (e.g. installed with --bindir).
    def wrapper(gem_spec = spec)
      return nil unless gem_spec

      path = File.join(Gem.bindir(gem_spec.base_dir), "chi")
      File.file?(path) ? path : nil
    end

    # What Bundler changed in ENV, mapped back to the values from before it
    # (nil: unset); {} outside Bundler. Child chi commands use this in gem
    # mode so they load the same installed gem without inheriting this app's
    # bundle.
    def unbundled_env_changes(env = ENV.to_h)
      return {} unless defined?(::Bundler) && ::Bundler.respond_to?(:unbundled_env)

      clean = ::Bundler.unbundled_env
      (env.keys | clean.keys).each_with_object({}) { |key, changes| changes[key] = clean[key] unless clean[key] == env[key] }
    end

    def real_path(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end
  end
end
