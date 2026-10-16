# frozen_string_literal: true

module Samagotchi
  # The XDG base directories chi keeps its files under, read from +env+ on
  # every call (specs and smoke runs point XDG_* elsewhere after load):
  #   state:  $XDG_STATE_HOME  or ~/.local/state  (sessions, logs, history, plugin data)
  #   config: $XDG_CONFIG_HOME or ~/.config       (config.yml, memories, hooks)
  # A blank variable counts as unset. A relative one is made absolute from
  # the current directory (File.absolute_path: no ~ expansion), so a command
  # run in another cwd (execute's logs and exit_code file) still finds it.
  # The samagotchi folder inside each is #state_dir / ConfigFile.config_dir.
  module Paths
    APP_DIR = "samagotchi"

    module_function

    # @return [String] $XDG_STATE_HOME (absolute), else ~/.local/state
    def state_home(env: ENV)
      xdg = env.fetch("XDG_STATE_HOME", "").to_s.strip
      xdg.empty? ? File.join(Dir.home, ".local", "state") : File.absolute_path(xdg)
    end

    # @return [String] <state home>/samagotchi
    def state_dir(env: ENV)
      File.join(state_home(env: env), APP_DIR)
    end

    # @return [String] $XDG_CONFIG_HOME (absolute), else ~/.config
    def config_home(env: ENV)
      xdg = env.fetch("XDG_CONFIG_HOME", "").to_s.strip
      xdg.empty? ? File.expand_path("~/.config") : File.absolute_path(xdg)
    end

    # +path+ as chi shows it: ~ for the home folder (~/a for one in it),
    # else as it is; as it is too when there's no home (HOME unset).
    # @return [String]
    def tilde(path)
      path = path.to_s
      home = Dir.home
      return "~" if path == home

      path.start_with?("#{home}/") ? "~#{path.delete_prefix(home)}" : path
    rescue ArgumentError
      path
    end
  end
end
