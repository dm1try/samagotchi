# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "atomic_file"

module Samagotchi
  # A worker's bridge.json in its session directory: how clients reach its
  # Bridge (port, bind), when it started (a new worker behind the same
  # "worker" owner), the chi it runs (chi update) and the input-file format
  # it reads (SessionManager::INPUT_FORMAT). The Bridge writes it on start
  # and removes it on stop; one a dead worker left stays until a client's
  # probe finds its port closed (BridgeClient.sidecar_port).
  class WorkerSidecar < Data.define(:port, :bind, :session_id, :started_at, :version, :input_format)
    FILE = "bridge.json"

    def self.path(session_dir) = File.join(session_dir, FILE)

    # @return [WorkerSidecar, nil] nil when there is none, or it is not a
    #   JSON object; port is 0 when it names none
    def self.read(session_dir)
      data = JSON.parse(File.read(path(session_dir)))
      return nil unless data.is_a?(Hash)

      port = data["port"]
      new(port: port.respond_to?(:to_i) ? port.to_i : 0, bind: data["bind"], session_id: data["session_id"],
          started_at: data["started_at"], version: data["version"], input_format: data["input_format"])
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def initialize(port:, bind: nil, session_id: nil, started_at: nil, version: nil, input_format: nil) = super

    # Written whole or not at all; input_format only when it names one.
    def write(session_dir)
      FileUtils.mkdir_p(session_dir)
      record = to_h.transform_keys(&:to_s)
      record.delete("input_format") if input_format.nil?
      AtomicFile.write(self.class.path(session_dir), "#{JSON.pretty_generate(record)}\n")
    end
  end
end
