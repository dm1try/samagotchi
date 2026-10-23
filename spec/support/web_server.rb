# frozen_string_literal: true

require "webrick"
require "rackup"

# chi web's Web::App served for real, as `chi web` serves it (rackup's
# WEBrick: a hijacked stream is raw bytes, not chunked), on 127.0.0.1 and
# a free port, in a thread: for a spec that needs a socket a Rack mock can't
# give (the event stream through chi web, spec/remote_attach_stream_spec.rb).
#
#   server = WebServer.start(app)
#   server.url # => "http://127.0.0.1:54321"
#   server.stop
#
# Loopback: chi web's LAN token gate doesn't run for a 127.0.0.1 peer.
module WebServer
  Running = Data.define(:port, :server, :thread) do
    def url = "http://127.0.0.1:#{port}"

    def stop
      server.shutdown
      thread.join(5)
    end
  end

  # @param app [Samagotchi::Web::App]
  # @return [Running] listening
  def self.start(app)
    ready = Queue.new
    thread = Thread.new do
      Rackup::Handler::WEBrick.run(app, Host: "127.0.0.1", Port: 0, AccessLog: [],
                                        Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL)) do |server|
        app.server_running = -> { server.status == :Running }
        ready << server
      end
    end
    thread.report_on_exception = false
    server = SpecWaiting.pop!(ready, "the web server to start")
    Running.new(port: server.listeners.first.addr[1], server: server, thread: thread)
  end
end
