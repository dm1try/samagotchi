# frozen_string_literal: true

module Samagotchi
  # chi's files (memories, AGENT.md, sessions, config.yml) are UTF-8,
  # whatever the locale. Under LC_ALL=C (or with no locale at all: an app
  # started from Finder or launchd, `env -i`) Ruby reads files as US-ASCII,
  # and a UTF-8 memory index then breaks the system prompt
  # (Encoding::CompatibilityError). bin/chi and every worker call #apply!
  # first.
  module Utf8Default
    LOCALE_KEYS = %w[LC_ALL LC_CTYPE LANG].freeze

    # Files read as UTF-8 when the locale says US-ASCII. With no locale set
    # at all, LANG too, so the workers and tools chi spawns get one; a
    # locale the user set (LC_ALL=C) is left to them.
    def self.apply!(env = ENV)
      return unless Encoding.default_external == Encoding::US_ASCII

      env["LANG"] = "en_US.UTF-8" if LOCALE_KEYS.none? { |key| env[key] }
      verbose = $VERBOSE
      begin
        $VERBOSE = nil # Encoding.default_external= warns
        Encoding.default_external = Encoding::UTF_8
      ensure
        $VERBOSE = verbose
      end
    end
  end
end
