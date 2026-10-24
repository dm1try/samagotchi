#!/usr/bin/env ruby
# frozen_string_literal: true

# A stand-in for an auth proxy in front of chi web, stdlib only, for the
# proxy e2e (proxy.spec.js). It behaves as oauth2-proxy v7 does upstream
# (checked against the real one, p6-local-spike.md §7):
#   https://<port>.<domain>:<listen>/  ->  http://127.0.0.1:<port>/   (Host passed through)
# - signed in (a cookie for Domain=<domain>, every port's subdomain shares
#   it): the request goes upstream with X-Forwarded-Email / X-Forwarded-User
#   set by the proxy (client copies, underscore twins too, dropped), the
#   client's X-Forwarded-For kept and the peer appended, the client's
#   X-Forwarded-Host / -Proto passed through untouched;
# - not signed in: 401 {} for Accept: application/json, else a 302 to
#   /oauth2/sign_in?rd=…, which signs in as the --auto user straight away
#   (an IdP with a session: the 302 chain keeps the URL's #fragment) or,
#   with auto off, shows a sign-in page (HTML);
# - GET /oauth2/expire ends the sign-in, turns auto off and cuts the open
#   streams (an EventSource then reconnects into the sign-in page).
# Bodies are streamed per read (re-chunked when length-less: SSE arrives as
# it is written).
#
#   ruby pod_proxy.rb --port 8443 --cert-dir DIR [--domain pod.localhost] [--auto owner@pod.test]

require "fileutils"
require "json"
require "openssl"
require "optparse"
require "socket"
require "uri"

module PodProxy
  COOKIE = "_oauth2_proxy"
  STRIPPED = %w[x-forwarded-email x-forwarded-user x-forwarded-preferred-username x-forwarded-groups].freeze
  HOP = %w[connection keep-alive proxy-connection te trailer upgrade proxy-authorization content-length host].freeze

  State = Struct.new(:port, :domain, :cert_dir, :auto, :sessions, :streams, :mutex, keyword_init: true)

  module_function

  def parse(argv)
    state = State.new(port: 8443, domain: "pod.localhost", cert_dir: Dir.pwd, auto: nil, sessions: {}, streams: [],
                      mutex: Mutex.new)
    OptionParser.new do |op|
      op.on("--port N", Integer) { |v| state.port = v }
      op.on("--domain NAME") { |v| state.domain = v }
      op.on("--cert-dir DIR") { |v| state.cert_dir = v }
      op.on("--auto EMAIL") { |v| state.auto = v }
    end.parse!(argv)
    state
  end

  def tls_context(state)
    FileUtils.mkdir_p(state.cert_dir)
    key = OpenSSL::PKey::RSA.new(2048)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(1 << 62)
    cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{state.domain}")
    cert.public_key = key.public_key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 86_400
    ef = OpenSSL::X509::ExtensionFactory.new(cert, cert)
    cert.add_extension(ef.create_extension("subjectAltName", "DNS:#{state.domain},DNS:*.#{state.domain},IP:127.0.0.1"))
    cert.sign(key, OpenSSL::Digest.new("SHA256"))
    File.write(File.join(state.cert_dir, "pod-proxy.crt"), cert.to_pem)
    ctx = OpenSSL::SSL::SSLContext.new
    ctx.cert = cert
    ctx.key = key
    ctx.alpn_protocols = ["http/1.1"]
    ctx
  end

  def handle(client, state, peer)
    head = read_head(client) or return
    method, target, = head[:line].split(" ", 3)
    headers = head[:headers]
    host = header(headers, "host").to_s
    body = read_body(client, headers)
    sid = cookie(headers)
    email = state.mutex.synchronize { state.sessions[sid] }
    return oauth(client, state, method, host, target, sid) if target.start_with?("/oauth2/")

    unless email
      return respond(client, 401, "application/json", "{}") if header(headers, "accept").to_s.include?("application/json")

      rd = URI.encode_www_form_component("https://#{host}#{target}")
      return respond(client, 302, "text/html", "", "Location" => "https://#{host}/oauth2/sign_in?rd=#{rd}")
    end

    port = host.sub(/:\d+\z/, "").downcase[/\A(\d+)\.#{Regexp.escape(state.domain)}\z/, 1]&.to_i
    return respond(client, 502, "text/plain", "no upstream for #{host}\n") unless port

    forward(client, state, method, target, headers, body, host, port, peer, email)
  rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNREFUSED, IOError
    nil
  ensure
    begin
      client.close
    rescue IOError, OpenSSL::SSL::SSLError
      nil
    end
  end

  def forward(client, state, method, target, headers, body, host, port, peer, email)
    kept = headers.reject { |name, _| HOP.include?(name.downcase) || STRIPPED.include?(name.downcase.tr("_", "-")) }
    xff = [header(headers, "x-forwarded-for"), peer].compact.join(", ")
    kept = kept.reject { |name, _| name.casecmp?("x-forwarded-for") }
    out = [["Host", host], *kept, ["X-Forwarded-For", xff], ["X-Forwarded-Email", email],
           ["X-Forwarded-User", email.split("@").first], %w[Connection close]]
    up = TCPSocket.new("127.0.0.1", port, connect_timeout: 3)
    state.mutex.synchronize { state.streams << client }
    request = "#{method} #{target} HTTP/1.1\r\n"
    out.each { |name, value| request << "#{name}: #{value}\r\n" }
    request << "Content-Length: #{body.bytesize}\r\n" if body
    request << "\r\n"
    up.write(request)
    up.write(body) if body
    relay(up, client)
  ensure
    state.mutex.synchronize { state.streams.delete(client) }
    up&.close
  end

  def relay(up, client)
    head = read_head(up) or return
    status = head[:line][%r{\AHTTP/1\.[01] (\d{3})}, 1].to_i
    out_headers = head[:headers].reject { |name, _| %w[connection keep-alive transfer-encoding].include?(name.downcase) }
    length = header(head[:headers], "content-length")
    chunked = header(head[:headers], "transfer-encoding").to_s.downcase.include?("chunked")
    rechunk = length.nil? && !chunked && ![204, 304].include?(status)
    out_headers << %w[Transfer-Encoding chunked] if rechunk || chunked
    bytes = "#{head[:line]}\r\n"
    out_headers.each { |name, value| bytes << "#{name}: #{value}\r\n" }
    client.write("#{bytes}Connection: close\r\n\r\n")
    loop do
      chunk = up.readpartial(16_384)
      client.write(rechunk ? "#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n" : chunk)
      client.flush
    end
  rescue EOFError
    client.write("0\r\n\r\n") if rechunk
  end

  def oauth(client, state, method, _host, target, sid)
    uri = URI.parse("https://x#{target}")
    query = URI.decode_www_form(uri.query.to_s).to_h
    case [method, uri.path]
    when ["GET", "/oauth2/sign_in"]
      rd = query["rd"].to_s
      rd = "/" unless rd.match?(%r{\Ahttps://[^/]*\.#{Regexp.escape(state.domain)}(:\d+)?/})
      return respond(client, 200, "text/html", "<!doctype html><title>Sign in</title><h1>Fake sign-in</h1>") unless state.auto

      fresh = OpenSSL::Random.random_bytes(16).unpack1("H*")
      state.mutex.synchronize { state.sessions[fresh] = state.auto }
      respond(client, 302, "text/plain", "", "Location" => rd,
                                             "Set-Cookie" => "#{COOKIE}=#{fresh}; Domain=#{state.domain}; Path=/; Secure; HttpOnly; SameSite=Lax")
    when ["GET", "/oauth2/expire"]
      streams = state.mutex.synchronize do
        state.sessions.delete(sid)
        state.auto = nil
        state.streams.dup
      end
      streams.each do |stream|
        stream.close
      rescue IOError, OpenSSL::SSL::SSLError
        nil
      end
      respond(client, 200, "application/json", JSON.generate(expired: true))
    else
      respond(client, 404, "text/plain", "not found\n")
    end
  end

  def header(headers, name) = headers.find { |n, _| n.downcase == name }&.last

  def cookie(headers)
    headers.select { |n, _| n.downcase == "cookie" }.flat_map { |_, v| v.split(/;\s*/) }
           .find { |pair| pair.start_with?("#{COOKIE}=") }&.split("=", 2)&.last
  end

  def read_head(io)
    line = io.gets("\r\n") or return nil
    headers = []
    while (l = io.gets("\r\n"))
      break if l == "\r\n"

      name, value = l.chomp.split(":", 2)
      headers << [name.strip, value.to_s.strip]
    end
    { line: line.chomp, headers: headers }
  end

  def read_body(io, headers)
    length = header(headers, "content-length").to_i
    length.positive? ? io.read(length) : nil
  end

  def respond(client, status, type, body, extra = {})
    reason = { 200 => "OK", 302 => "Found", 401 => "Unauthorized", 404 => "Not Found", 502 => "Bad Gateway" }[status]
    head = "HTTP/1.1 #{status} #{reason}\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n"
    extra.each { |name, value| head << "#{name}: #{value}\r\n" }
    client.write("#{head}Connection: close\r\n\r\n#{body}")
  end

  def run(argv)
    state = parse(argv)
    server = OpenSSL::SSL::SSLServer.new(TCPServer.new("127.0.0.1", state.port), tls_context(state))
    server.start_immediately = false
    $stdout.puts "pod_proxy ready on #{state.port}"
    $stdout.flush
    loop do
      raw = server.accept
      Thread.new(raw) do |conn|
        peer = conn.to_io.peeraddr[3]
        conn.accept
        handle(conn, state, peer)
      rescue OpenSSL::SSL::SSLError, Errno::ECONNRESET, IOError
        begin
          conn.close
        rescue IOError
          nil
        end
      end
    end
  end
end

PodProxy.run(ARGV) if $PROGRAM_NAME == __FILE__
