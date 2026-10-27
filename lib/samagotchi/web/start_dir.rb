# frozen_string_literal: true

module Samagotchi
  module Web
    # The folder chi web starts in (web.start_dir, chi web --start-dir): the
    # project its bare page shows, and where a new session from the all view
    # (or one created without a dir) starts. chi web's own cwd when unset; it
    # never changes chi web's cwd.
    module StartDir
      class Invalid < StandardError; end

      # Where +given+ came from, as its error names it.
      SOURCES = { flag: "--start-dir", config: "web.start_dir in config.yml" }.freeze

      # +given+ as an absolute folder (~ expanded, a relative one against
      # +cwd+, or the home folder for a config value); nil or blank: +cwd+.
      # @param from [Symbol] :flag or :config (SOURCES)
      # @raise [Invalid] when it is no folder
      def self.resolve(given, cwd: Dir.pwd, from: :flag)
        return File.expand_path(cwd) if given.nil? || given.to_s.strip.empty?

        source = SOURCES.fetch(from)
        dir = File.expand_path(given.to_s.strip, from == :config ? Dir.home : cwd)
        raise Invalid, "#{source} #{given}: no such folder" unless File.exist?(dir)
        raise Invalid, "#{source} #{given}: not a folder" unless File.directory?(dir)

        dir
      end
    end
  end
end
