# frozen_string_literal: true

require_relative "config"
require_relative "session"
require_relative "version"
require_relative "worker_link"
require_relative "web/info_probe"
require_relative "web/running"

module Samagotchi
  # Which chi versions the running processes run, for `chi update`: session
  # workers (their bridge.json sidecar names the version since chi update exists; an
  # older one names none) and a `chi web` on its port (/api/info): also
  # chi self's and chi share's lookup of that chi web. Read-only: a dead
  # worker's sidecar is left for the next client to clean up.
  module LiveVersions
    WEB_TIMEOUT = 0.5
    # chi web's port when config names none: Web::Server::DEFAULT_PORT,
    # without loading chi web.
    DEFAULT_WEB_PORT = 4567

    # version is nil for a sidecar written before sidecars carried one;
    # restart: the worker takes `chi sessions restart` (its "restart" feature).
    Worker = Struct.new(:session_id, :version, :restart, keyword_init: true)
    # The port a chi web answers on and its /api/info.
    WebAnswer = Data.define(:port, :info)

    module_function

    # @return [Array<Worker>] the workers whose Bridge answers, by session id
    def workers(state_dir: Session.default_state_dir)
      WorkerLink.each_dir(state_dir).filter_map do |session_dir|
        link = WorkerLink.resolve(session_dir, unlink: false)
        next unless link.live?

        Worker.new(session_id: File.basename(session_dir), version: link.version,
                   restart: link.features.include?("restart"))
      end
    end

    # The live workers on another version than +version+ (unknown counts).
    def stale_workers(version = VERSION, state_dir: Session.default_state_dir)
      workers(state_dir: state_dir).reject { |w| w.version == version }
    end

    # The /api/info of a chi web on host:port, or nil when nothing (or not
    # chi web) answers.
    def web_info(host, port, timeout: WEB_TIMEOUT)
      info = Web::InfoProbe.call(host, port, timeout: timeout)
      info.is_a?(Hash) ? info : nil
    end

    # Config's web.port, or the default for none that is a port.
    def configured_web_port
      port = Config.get("web.port").to_s.to_i
      port.positive? ? port : DEFAULT_WEB_PORT
    end

    # The chi web on this machine: on the port the running one recorded (a
    # --port it was started with is not config's), else on +configured+.
    # @param path [String] its record (Web::Running.path)
    # @return [WebAnswer, nil] nil with none
    def web_answering(host, configured, path:, timeout: WEB_TIMEOUT)
      [Web::Running.port(path: path), configured].compact.uniq.each do |port|
        info = web_info(host, port, timeout: timeout)
        return WebAnswer.new(port: port, info: info) if info
      end
      nil
    end
  end
end
