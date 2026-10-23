# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../atomic_file"
require_relative "../session"

module Samagotchi
  module Web
    # Where this machine's chi web listens: $XDG_STATE_HOME/samagotchi/web.json
    # ({pid, port}), written once its port is bound and removed when it
    # stops (by that process only). A command that names chi web in what it
    # prints (chi share's link) reads the port here before config's
    # web.port, which a chi web started with --port or another config
    # doesn't follow. The file is a hint: a chi web killed hard leaves it,
    # so a reader probes the port (InfoProbe) before trusting it.
    module Running
      FILE = "web.json"

      module_function

      def path(state_dir: nil, env: ENV)
        File.join(File.dirname(state_dir || Session.default_state_dir(env: env)), FILE)
      end

      # @return [String] +path+
      def record(port:, path: self.path, pid: Process.pid)
        FileUtils.mkdir_p(File.dirname(path))
        AtomicFile.write(path, JSON.generate({ pid: pid, port: port }))
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

      def read(path)
        data = JSON.parse(File.read(path))
        data.is_a?(Hash) ? data : nil
      rescue Errno::ENOENT, JSON::ParserError
        nil
      end
    end
  end
end
