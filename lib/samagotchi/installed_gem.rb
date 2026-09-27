# frozen_string_literal: true

module Samagotchi
  # Whether this code runs as an installed gem. A source checkout (bin/chi,
  # or bundle exec with the Gemfile's `gemspec`) is not one.
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

    def real_path(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end
  end
end
