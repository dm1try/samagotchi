# frozen_string_literal: true

module Samagotchi
  # The XDG base directories chi keeps its files under, read from +env+ on
  # every call (specs and smoke runs point XDG_* elsewhere after load):
  #   state:  $XDG_STATE_HOME  or ~/.local/state  (sessions, logs, history, plugin data)
  #   config: $XDG_CONFIG_HOME or ~/.config       (config.yml, memories, hooks)
  # A blank variable counts as unset. The samagotchi folder inside each is
  # #state_dir / ConfigFile.config_dir.
  module Paths
    APP_DIR = "samagotchi"

    module_function

    # @return [String] $XDG_STATE_HOME, else ~/.local/state
    def state_home(env: ENV)
      xdg = env.fetch("XDG_STATE_HOME", "").to_s.strip
      xdg.empty? ? File.join(Dir.home, ".local", "state") : xdg
    end

    # @return [String] <state home>/samagotchi
    def state_dir(env: ENV)
      File.join(state_home(env: env), APP_DIR)
    end

    # @return [String] $XDG_CONFIG_HOME, else ~/.config
    def config_home(env: ENV)
      xdg = env.fetch("XDG_CONFIG_HOME", "").to_s.strip
      xdg.empty? ? File.expand_path("~/.config") : xdg
    end
  end
end
