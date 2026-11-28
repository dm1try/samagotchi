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
      # web.ask_dir (a thin client's create, Web::AskCreate) may come from
      # config.yml or SAMAGOTCHI_WEB_ASK_DIR: named alone.
      SOURCES = { flag: "--start-dir", config: "web.start_dir in config.yml", ask_config: "web.ask_dir" }.freeze

      # +given+ as an absolute folder (~ expanded, a relative one against
      # +cwd+, or the home folder for a setting's value); nil or blank: +cwd+.
      # @param from [Symbol] :flag, :config or :ask_config (SOURCES)
      # @raise [Invalid] when it is no folder
      def self.resolve(given, cwd: Dir.pwd, from: :flag)
        return File.expand_path(cwd) if given.nil? || given.to_s.strip.empty?

        source = SOURCES.fetch(from)
        dir = File.expand_path(given.to_s.strip, from == :flag ? cwd : Dir.home)
        raise Invalid, "#{source} #{given}: no such folder" unless File.exist?(dir)
        raise Invalid, "#{source} #{given}: not a folder" unless File.directory?(dir)

        dir
      end
    end
  end
end
