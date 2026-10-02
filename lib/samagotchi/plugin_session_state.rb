# frozen_string_literal: true

require "fileutils"
require_relative "paths"
require_relative "session"

module Samagotchi
  # A plugin's state for one session, by convention under its data dir
  # (ctx.data_dir): sessions/<id>.json or sessions/<id>/. It goes when the
  # session does (SessionManager.delete_session: the CLI, the web, a
  # discarded empty session; SessionRetention's prune), so no bundle keeps
  # state for sessions that are gone (check-in's /checkin settings).
  module PluginSessionState
    module_function

    # @return [Array<String>] the paths removed
    def remove(session_id, env: ENV)
      id = session_id.to_s
      # Only a plain id: anything else could name a path outside the dir.
      return [] unless Session.valid_id?(id)

      Dir.glob(File.join(Paths.state_dir(env: env), "plugins", "*", "sessions")).flat_map do |dir|
        [File.join(dir, "#{id}.json"), File.join(dir, id)].select { |path| File.exist?(path) }
                                                         .each { |path| FileUtils.rm_rf(path) }
      end
    rescue SystemCallError
      []
    end
  end
end
