# frozen_string_literal: true

require "rack/mock"
require "samagotchi/web/app"
require "samagotchi/session_manager"
require "samagotchi/remotes"
require "samagotchi/session_access/remote"

# SessionAccess::Remote against chi web's Rack app in this process: no
# socket, the same state dir (so a spec's sessions, owner locks and stubs
# are the server's too), and LAN mode, so every request passes the token
# gate as a laptop's would (another peer, the LAN IP as Host, Bearer).
module RemoteBackend
  LAN_IP = "192.0.2.10"
  PEER = "192.0.2.20"
  TOKEN = "spec-token"

  # chi web's answers to a Remote, through App#call.
  class RackTransport
    attr_reader :requests

    def initialize(app, token: TOKEN)
      @app = app
      @token = token
      @requests = []
    end

    def call(method, path, query: nil, body: nil, raw: nil, content_type: nil)
      params = query&.compact
      target = params && !params.empty? ? "#{path}?#{URI.encode_www_form(params)}" : path
      @requests << [method, target]
      headers = { "HTTP_HOST" => "#{LAN_IP}:4567", "REMOTE_ADDR" => PEER, method: method.to_s.upcase }
      headers["HTTP_AUTHORIZATION"] = "Bearer #{@token}" if @token
      if raw
        headers[:input] = raw
        headers["CONTENT_TYPE"] = content_type || "application/octet-stream"
      elsif body
        headers[:input] = JSON.generate(body)
        headers["CONTENT_TYPE"] = "application/json"
      end
      status, _headers, chunks = @app.call(Rack::MockRequest.env_for(target, headers))
      text = +""
      chunks.each { |chunk| text << chunk }
      chunks.close if chunks.respond_to?(:close)
      Samagotchi::SessionAccess::HTTPTransport::Reply.of(status, text)
    end
  end

  module_function

  def entry(name: "studio", token: TOKEN)
    Samagotchi::Remotes::Entry.new(name: name, url: "http://#{LAN_IP}:4567", token: token)
  end

  def app(state_dir:)
    Samagotchi::Web::App.new(manager: Samagotchi::SessionManager, state_dir: state_dir, bridge_wait_timeout: 0,
                             wait_poll_interval: 0.01, lan: { ip: LAN_IP, token: TOKEN })
  end

  # A Remote on +state_dir+'s sessions (through +app+, chi web's).
  def access(state_dir:, token: TOKEN, name: "studio", app: nil)
    Samagotchi::SessionAccess::Remote.new(entry(name: name, token: token),
                                          transport: RackTransport.new(app || self.app(state_dir: state_dir), token: token),
                                          sleeper: ->(_seconds) {})
  end

  # The example group's DSL: the block's examples once per backend, in a
  # context named for it; +backend+ (:local or :remote) inside. An example
  # tagged local_only: "why" is skipped on the remote one (its words or
  # its checks are this machine's).
  #
  #   RemoteBackend.both(self) do
  #     def run(*argv) = described_class.new(argv, access: backend_access(tmpdir)).run
  #     it "…" do … end
  #   end
  def both(group, &body)
    %i[local remote].each do |backend|
      group.context("on the #{backend} backend", backend: backend) do
        let(:backend) { backend }
        before do |example|
          reason = example.metadata[:local_only]
          skip("local only: #{reason}") if backend == :remote && reason
        end

        # nil (the command's own Local) or a Remote on +state_dir+.
        define_method(:backend_access) do |state_dir|
          return nil unless backend == :remote

          @backend_access ||= RemoteBackend.access(state_dir: state_dir, app: backend_app(state_dir))
        end

        # The remote backend's chi web (an example stubs its Bridge client).
        define_method(:backend_app) do |state_dir|
          @backend_app ||= RemoteBackend.app(state_dir: state_dir)
        end

        class_exec(&body)
      end
    end
  end
end
