# frozen_string_literal: true

module Samagotchi
  module Web
    # The folder chi web starts in (web.start_dir, chi web --start-dir): the
    # project its bare page shows, and where a new session from the all view
    # (or one created without a dir) starts. chi web's own cwd when unset; it
    # never changes chi web's cwd.
    module StartDir
      class Invalid < StandardError; end

      # +given+ as an absolute folder (~ expanded, a relative one against
      # +cwd+); nil or blank: +cwd+.
      # @raise [Invalid] when it is no folder
      def self.resolve(given, cwd: Dir.pwd)
        return File.expand_path(cwd) if given.nil? || given.to_s.strip.empty?

        dir = File.expand_path(given.to_s.strip, cwd)
        raise Invalid, "--start-dir #{given}: no such folder" unless File.exist?(dir)
        raise Invalid, "--start-dir #{given}: not a folder" unless File.directory?(dir)

        dir
      end
    end
  end
end
