# frozen_string_literal: true

require "json"
require "net/http"
require "socket"
require_relative "session"
require_relative "version"
require_relative "worker_sidecar"

module Samagotchi
  # Which chi versions the running processes run, for `chi update`: session
  # workers (their bridge.json sidecar names the version since chi update exists; an
  # older one names none) and a `chi web` on its port (/api/info). Read-only:
  # a dead worker's sidecar is left for the next client to clean up.
  module LiveVersions
    PROBE_TIMEOUT = 0.2
    WEB_TIMEOUT = 0.5

    # version is nil for a sidecar written before sidecars carried one.
    Worker = Struct.new(:session_id, :version, keyword_init: true)

    module_function

    # @return [Array<Worker>] the workers whose Bridge answers, by session id
    def workers(state_dir: Session.default_state_dir)
      Dir[File.join(state_dir, "*", WorkerSidecar::FILE)].sort.filter_map do |path|
        session_dir = File.dirname(path)
        sidecar = WorkerSidecar.read(session_dir)
        next unless sidecar && listening?(sidecar.port)

        Worker.new(session_id: File.basename(session_dir), version: sidecar.version)
      end
    end

    # The live workers on another version than +version+ (unknown counts).
    def stale_workers(version = VERSION, state_dir: Session.default_state_dir)
      workers(state_dir: state_dir).reject { |w| w.version == version }
    end

    # The version a chi web on host:port runs, or nil when nothing (or not
    # chi web) answers.
    def web_version(host, port, timeout: WEB_TIMEOUT)
      web_info(host, port, timeout: timeout)&.fetch("version", nil).to_s.then { |v| v.empty? ? nil : v }
    end

    # The /api/info of a chi web on host:port, or nil when nothing (or not
    # chi web) answers.
    def web_info(host, port, timeout: WEB_TIMEOUT)
      response = Net::HTTP.start(host, port, open_timeout: timeout, read_timeout: timeout) { |http| http.get("/api/info") }
      info = response.code.to_i == 200 ? JSON.parse(response.body.to_s) : nil
      info.is_a?(Hash) && info["app"] == "chi-web" ? info : nil
    rescue StandardError
      nil
    end

    def listening?(port, host: "127.0.0.1")
      return false unless port.positive?

      Socket.tcp(host, port, connect_timeout: PROBE_TIMEOUT).close
      true
    rescue StandardError
      false
    end
  end
end
