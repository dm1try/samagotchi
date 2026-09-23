# frozen_string_literal: true

require "json"
require "webrick"

# An in-process OpenAI-compatible server for provider specs. It replays the
# recorded fixtures in spec/fixtures/providers/openai (or any body a spec
# gives it) over real HTTP and records every request, so specs exercise the
# real Net::HTTP, SSE, retry and cancel code.
#
#   server = FakeProviderServer.start
#   server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))
#   ... server.base_url => "http://127.0.0.1:PORT/v1"
#   server.requests.last.json["messages"]
#   server.stop
#
# Responses are queued per path and served in order; a path with an empty
# queue answers its `default` (see #default) or 404. WebMock buffers a real
# response body before read_body yields, so wrap examples that use this
# server in `FakeProviderServer.without_webmock`.
class FakeProviderServer
  FIXTURE_DIR = File.expand_path("../fixtures/providers/openai", __dir__)

  Request = Struct.new(:method, :path, :headers, :body, keyword_init: true) do
    def json
      JSON.parse(body.to_s)
    end

    def header(name)
      headers[name.to_s.downcase]
    end
  end

  # A queued response: an HTTP status, headers, and either a plain body or
  # SSE chunks written one at a time (with an optional delay between them).
  # `hold:` keeps the stream open after the chunks until #release (cancel
  # specs); `drop:` closes the socket mid-stream without finishing it.
  Response = Struct.new(:status, :headers, :body, :chunks, :delay, :hold, :drop, keyword_init: true)

  def self.fixture(name)
    File.binread(File.join(FIXTURE_DIR, name))
  end

  # The status recorded next to a JSON fixture (e.g. error_400.status).
  def self.fixture_status(name)
    File.read(File.join(FIXTURE_DIR, "#{File.basename(name, ".*")}.status")).to_i
  end

  # Split an SSE body into its events ("data: …\n\n"), the unit a server
  # flushes, so a stream can be replayed event by event.
  def self.sse_events(body)
    body.split(/(?<=\n\n)/)
  end

  def self.start
    new.tap(&:start)
  end

  # Real sockets under WebMock: disable it for the block when it is loaded.
  def self.without_webmock
    return yield unless defined?(WebMock)

    WebMock.disable!
    begin
      yield
    ensure
      WebMock.enable!
    end
  end

  attr_reader :port

  def initialize
    @mutex = Mutex.new
    @queues = Hash.new { |hash, key| hash[key] = [] }
    @defaults = {}
    @requests = []
    @released = Queue.new
    @holding = 0
  end

  def start
    @server = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1", Port: 0,
      Logger: WEBrick::Log.new(File::NULL), AccessLog: []
    )
    @port = @server.config[:Port]
    @server.mount_proc("/") { |req, res| handle(req, res) }
    @thread = Thread.new { @server.start }
    self
  end

  # WEBrick notices a shutdown on its next 2s select tick; don't wait for it.
  def stop
    release
    @server&.shutdown
    @thread&.join(0.2) || @thread&.kill
  end

  def root_url = "http://127.0.0.1:#{@port}"
  def base_url = "#{root_url}/v1"

  def requests
    @mutex.synchronize { @requests.dup }
  end

  # Queue one response for +path+.
  # @param sse [String, Array<String>, nil] an SSE body (split into events)
  #   or its events; sent chunked with Content-Type text/event-stream
  # @param json [String, Hash, nil] a JSON body
  def enqueue(path, status: 200, sse: nil, json: nil, body: nil, headers: {}, delay: nil, hold: false, drop: false)
    @mutex.synchronize { @queues[path] << build(status, sse, json, body, headers, delay, hold, drop) }
    self
  end

  # The response +path+ answers when its queue is empty.
  def default(path, status: 200, sse: nil, json: nil, body: nil, headers: {}, delay: nil, hold: false, drop: false)
    @mutex.synchronize { @defaults[path] = build(status, sse, json, body, headers, delay, hold, drop) }
    self
  end

  # Let held streams finish.
  def release
    holding = @mutex.synchronize { @holding }
    holding.times { @released << true }
  end

  private

  def build(status, sse, json, body, headers, delay, hold, drop)
    chunks = nil
    if sse
      chunks = sse.is_a?(Array) ? sse : self.class.sse_events(sse)
      headers = { "Content-Type" => "text/event-stream" }.merge(headers)
    elsif json
      body = json.is_a?(String) ? json : JSON.generate(json)
      headers = { "Content-Type" => "application/json" }.merge(headers)
    end
    Response.new(status: status, headers: headers, body: body.to_s, chunks: chunks, delay: delay, hold: hold, drop: drop)
  end

  def handle(req, res)
    record(req)
    response = @mutex.synchronize { @queues[req.path].shift || @defaults[req.path] }
    unless response
      res.status = 404
      res["Content-Type"] = "application/json"
      res.body = JSON.generate(error: { message: "no fake response for #{req.path}" })
      return
    end

    res.status = response.status
    response.headers.each { |key, value| res[key] = value }
    if response.chunks
      res.chunked = true
      res.body = proc { |out| stream(out, response) }
    else
      res.body = response.body
    end
  end

  def stream(out, response)
    response.chunks.each_with_index do |chunk, index|
      sleep(response.delay) if response.delay && index.positive?
      out.write(chunk)
    end
    raise IOError, "dropped by the fake server" if response.drop
    return unless response.hold

    @mutex.synchronize { @holding += 1 }
    @released.pop
  end

  def record(req)
    headers = req.header.transform_values { |values| values.join(", ") }
    request = Request.new(method: req.request_method, path: req.path, headers: headers, body: req.body.to_s)
    @mutex.synchronize { @requests << request }
  end
end
