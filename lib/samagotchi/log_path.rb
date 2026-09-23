# frozen_string_literal: true

require_relative "config"

module Samagotchi
  # Where the debug log (DebugLog) goes, for the REPL, the attached terminal
  # and the background worker alike: nil when log.disable is set, else log.file
  # (~ and relative paths expanded against cwd), else
  # $XDG_STATE_HOME/samagotchi/samagotchi.log (~/.local/state/... by default),
  # next to the sessions and prompt history. Never inside the gem or checkout.
  module LogPath
    FILENAME = "samagotchi.log"

    module_function

    def resolve(env: ENV)
      return nil if Config.get("log.disable")

      configured = Config.get("log.file").to_s.strip
      return File.expand_path(configured) unless configured.empty?

      default_path(env: env)
    end

    def default_path(env: ENV)
      xdg = env.fetch("XDG_STATE_HOME", "").to_s.strip
      base = xdg.empty? ? File.join(Dir.home, ".local", "state") : xdg
      File.join(base, "samagotchi", FILENAME)
    end
  end
end
