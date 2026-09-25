# frozen_string_literal: true

require "rbconfig"

module Samagotchi
  # `chi desktop`: a small native helper that sends selected text to live
  # sessions as a context note. It talks to chi only through the CLI
  # (`chi sessions list --live --scope=all --format json`, `chi note`), so it could ship
  # on its own later. macOS only for now; a Linux variant would be another
  # class next to MacOS.
  module Desktop
    autoload :MacOS, "samagotchi/desktop/macos"

    module_function

    # @return [Boolean] whether this machine has a desktop helper variant
    def supported?(host_os = RbConfig::CONFIG["host_os"])
      host_os.to_s.include?("darwin")
    end
  end
end
