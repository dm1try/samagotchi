# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../atomic_file"
require_relative "../session"
require_relative "info_probe"
require_relative "public_url"

module Samagotchi
  module Web
    # Where this machine's chi web listens: $XDG_STATE_HOME/samagotchi/web.json
    # ({pid, port}, and public_url when it runs with one: config's or
    # --tunnel's), written once its port is bound and removed when it
    # stops (by that process only). A command that names chi web in what it
    # prints (chi share's link) reads the port here before config's
    # web.port, which a chi web started with --port or another config
    # doesn't follow. The file is a hint: a chi web killed hard leaves it,
    # so a reader probes the port (InfoProbe) before trusting it. One slot:
    # a second chi web on another port takes it over.
    module Running
      FILE = "web.json"
      PROBE_TIMEOUT = 1.0

      module_function

      def path(state_dir: nil, env: ENV)
        File.join(File.dirname(state_dir || Session.default_state_dir(env: env)), FILE)
      end

      # @return [String] +path+
      # @param public_url [String, nil] the https origin it runs behind
      def record(port:, path: self.path, pid: Process.pid, public_url: nil)
        FileUtils.mkdir_p(File.dirname(path))
        AtomicFile.write(path, JSON.generate({ pid: pid, port: port, public_url: public_url }.compact))
      end

      # Removes the file when this process wrote it (a second chi web's
      # file is left alone).
      def clear(path: self.path, pid: Process.pid)
        FileUtils.rm_f(path) if read(path)&.fetch("pid", nil) == pid
      end

      # @return [Integer, nil] the port the file names, nil without one
      def port(path: self.path)
        value = read(path)&.fetch("port", nil)
        value.is_a?(Integer) && value.positive? ? value : nil
      end

      # The public_url the running chi web recorded (a --tunnel's, which no
      # config has), for a link that names it: only while the chi web that
      # answers /api/info on the recorded port is the process that wrote the
      # file (its pid), and only an https origin. A record left by a chi web
      # killed hard, with a reused pid or another chi web (another state dir)
      # on that port, is nil. The origin is this file's, never the probe's.
      # @param probe [#call] (port) → InfoProbe's answer
      # @return [PublicUrl, nil]
      def live_public_url(path: self.path, probe: ->(port) { InfoProbe.call("127.0.0.1", port, timeout: PROBE_TIMEOUT) })
        data = read(path) or return nil
        pid, port, url = data.values_at("pid", "port", "public_url")
        return nil unless pid.is_a?(Integer) && pid.positive? && port.is_a?(Integer) && port.positive? && url.is_a?(String)
        return nil unless alive?(pid)

        info = probe.call(port)
        return nil unless info.is_a?(Hash) && info["pid"] == pid

        PublicUrl.from_config(url: url)
      rescue PublicUrl::Invalid
        nil
      end

      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def read(path)
        data = JSON.parse(File.read(path))
        data.is_a?(Hash) ? data : nil
      rescue Errno::ENOENT, JSON::ParserError
        nil
      end
    end
  end
end
