# frozen_string_literal: true

require "digest"
require_relative "config"

module Samagotchi
  # Where memories live: <config dir>/memories, i.e. $XDG_CONFIG_HOME/samagotchi/memories
  # or ~/.config/samagotchi/memories. Resolved on every call, like
  # ConfigFile.global_path, so an XDG_CONFIG_HOME set after load (specs, smoke runs,
  # a fixture chi) moves memories together with config.yml.
  module MemoryPaths
    module_function

    def system_dir(env: ENV)
      File.join(ConfigFile.config_dir(env: env), "memories")
    end

    def projects_dir(env: ENV)
      File.join(system_dir(env: env), "projects")
    end

    # One folder per working directory: basename + 8 hex chars of MD5(full path).
    def project_key(cwd = Dir.pwd)
      "#{File.basename(cwd)}_#{Digest::MD5.hexdigest(cwd)[0..7]}"
    end

    def project_dir(env: ENV, cwd: Dir.pwd)
      File.join(projects_dir(env: env), project_key(cwd))
    end

    def bundles_dir(env: ENV)
      File.join(system_dir(env: env), ".bundles")
    end
  end
end
