# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "atomic_file"

module Samagotchi
  # A worker's bridge.json in its session directory: how clients reach its
  # Bridge (port, bind), when it started (a new worker behind the same
  # "worker" owner), the chi it runs (chi update, the web's stale-worker
  # badge), the input-file format it reads (SessionInbox::INPUT_FORMAT) and
  # what else it can do (Bridge::FEATURES), and its Bridge's epoch (the
  # one worker identity: the epoch in every event id, so a remote client
  # tells a restarted worker apart; nil from a worker before it), and its
  # Bridge's secret (every request names it in X-Chi-Bridge, Bridge#secret_ok?;
  # nil from a worker before it, which asks for none), the pid of the worker
  # process that wrote it (WorkerLink: it is Live only under the owner lock
  # of that pid; nil from an older worker) and the WorkerLink::PROTOCOL it
  # speaks (nil from an older one). The Bridge writes it on start and removes
  # it on stop (only its own, by epoch); one a dead worker left stays until
  # a client finds the lock free (WorkerLink.resolve with unlink: true).
  class WorkerSidecar < Data.define(:port, :bind, :session_id, :started_at, :version, :input_format, :features,
                                    :epoch, :secret, :pid, :protocol)
    FILE = "bridge.json"

    def self.path(session_dir) = File.join(session_dir, FILE)

    # @return [WorkerSidecar, nil] nil when there is none, or it is not a
    #   JSON object; port is 0 when it names none
    def self.read(session_dir)
      data = JSON.parse(File.read(path(session_dir)))
      return nil unless data.is_a?(Hash)

      port = data["port"]
      new(port: port.respond_to?(:to_i) ? port.to_i : 0, bind: data["bind"], session_id: data["session_id"],
          started_at: data["started_at"], version: data["version"], input_format: data["input_format"],
          features: Array(data["features"]).map(&:to_s), epoch: data["epoch"]&.to_s, secret: secret_in(data["secret"]),
          pid: integer_in(data["pid"]), protocol: integer_in(data["protocol"]))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # The shape a Bridge's secret has (Bridge#initialize): anything else
    # (a hand-edited file) is read as none, so it never reaches a header.
    SECRET_SHAPE = /\A\h{32,128}\z/

    def self.secret_in(value) = value.is_a?(String) && SECRET_SHAPE.match?(value) ? value : nil

    def self.integer_in(value) = value.is_a?(Integer) ? value : nil

    def initialize(port:, bind: nil, session_id: nil, started_at: nil, version: nil, input_format: nil, features: [],
                   epoch: nil, secret: nil, pid: nil, protocol: nil) = super

    # The secret never shows in an inspect (a log line, an error's message).
    def inspect = "#<#{self.class.name} port=#{port} session_id=#{session_id.inspect} epoch=#{epoch.inspect}>"
    alias to_s inspect

    # Written whole or not at all, readable by this user only (0600 from the
    # moment the file exists, AtomicFile: no other account learns the
    # worker's port or its secret from it); input_format, epoch, secret, pid
    # and protocol only when they name one.
    def write(session_dir)
      FileUtils.mkdir_p(session_dir)
      record = to_h.transform_keys(&:to_s)
      record.delete("input_format") if input_format.nil?
      record.delete("epoch") if epoch.nil?
      record.delete("secret") if secret.nil?
      record.delete("pid") if pid.nil?
      record.delete("protocol") if protocol.nil?
      AtomicFile.write(self.class.path(session_dir), "#{JSON.pretty_generate(record)}\n", perm: 0o600)
    end
  end
end
