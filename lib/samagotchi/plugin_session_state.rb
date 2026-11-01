# frozen_string_literal: true

require "fileutils"
require_relative "paths"
require_relative "session"

module Samagotchi
  # A plugin's state for one session, under its data dir (ctx.data_dir):
  # sessions/<id>/ (ctx.session_dir), or sessions/<id>.json, the file a bundle
  # written before ctx.session_dir may still keep. It goes when the session
  # does (SessionManager.delete_session: the CLI, the web, a discarded empty
  # session; SessionRetention's prune), so no bundle keeps state for sessions
  # that are gone (check-in's /checkin settings).
  module PluginSessionState
    # What sessions/<id>.json becomes in the folder (.dir), the name the
    # shipped bundles that used it now write.
    STATE_FILE = "state.json"

    module_function

    # A session's folder under a bundle's +data_dir+, created. A
    # sessions/<id>.json there moves in as STATE_FILE, so a running session
    # keeps it when its bundle moves to ctx.session_dir.
    # @return [String, nil] nil for an id that isn't a plain one (it could
    #   name a path outside the dir)
    def dir(data_dir, session_id)
      id = session_id.to_s
      return nil unless Session.valid_id?(id)

      path = File.join(data_dir, "sessions", id)
      FileUtils.mkdir_p(path)
      adopt("#{path}.json", File.join(path, STATE_FILE))
      path
    end

    def adopt(old, state)
      File.rename(old, state) if File.file?(old) && !File.exist?(state)
    rescue SystemCallError
      nil # another worker's move, or a file that stays where it is
    end
    private_class_method :adopt

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
