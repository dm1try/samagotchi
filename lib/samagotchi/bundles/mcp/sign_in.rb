# frozen_string_literal: true

# The mcp bundle's sign-in plugin part (manifest.yml plugin: parts:, loaded
# before plugin.rb): /mcp login|logout and a 401's sign-in card, wired to
# the OAuth in oauth.rb.
require "digest"
require "uri"

class Plugin
  private

  # ── Sign-in (the OAuth in oauth.rb; here its wiring) ──────────────────

  # Why /mcp login|logout can't act on server +name+, nil when it can.
  def sign_in_refusal(name)
    server = @servers.find { |s| s.name == name }
    return "no MCP server #{name}#{" (#{@servers.map(&:name).join(", ")})" unless @servers.empty?}" unless server
    return "#{name} is a local server: sign-in is for remote ones (url:)" unless server.url
    return "#{name} has a static token (bearer_token_env: or an Authorization header): it doesn't sign in" unless server.signs_in
    return "#{name}'s url: has a query: chi can't sign in to it (it would go out with the sign-in)" if URI.parse(server.url).query

    config_error(server)
  end

  # /mcp login NAME: answers at once; discovery, the client, the flow and
  # the exchange run on a thread of the plugin's (OAuth::Login), whose
  # result or error replaces the flow's card.
  def login(name, ctx)
    refusal = sign_in_refusal(name)
    return refusal if refusal
    return "sign-in needs the web or a terminal: this run is one-shot" if ctx.frontend == :one_shot
    if @settings.key?("client_metadata_url") && @settings["client_metadata_url"] != false && client_metadata_url.nil?
      return "bundles: mcp: client_metadata_url: must be an https address with a path (chi's client document)"
    end
    return "this chi can't sign in (it has no ctx.sign_in)" unless ctx.respond_to?(:sign_in) && ctx.respond_to?(:secrets)

    server = @servers.find { |s| s.name == name }
    return "#{name} is signed in already (from another session): connected." if signed_in_elsewhere?(server, ctx)

    started = @sign_in_lock.synchronize do
      next false if @sign_ins[name]&.alive? || @sign_in_cancel.cancelled?

      @sign_ins[name] = Thread.new { sign_in(server, ctx) }
    end
    return "a sign-in to #{name} is already waiting: finish it in the browser, or let it time out" unless started

    "Opening sign-in for #{name}…"
  end

  # The login's thread: every error ends on a card, never raised into nothing.
  def sign_in(server, ctx)
    login = OAuth::Login.new(ctx: ctx, server: server, secret_lookup: ->(name) { env_value(server, name) },
                             client_metadata_url: client_metadata_url, cimd_refused: @cimd_refused, cancel: @sign_in_cancel,
                             log: ->(event, **fields) { ctx.log.info("mcp_#{event}", **fields) })
    card_id = login.run
    signed_in(server, card_id, ctx) if card_id
  rescue OAuth::Refusal => e
    ctx.log.warn("mcp_sign_in_failed", server: server.name, error: e.class.name)
    ctx.card(id: e.card_id, title: "Sign-in to #{server.name} failed", body: e.message, level: :warn, between_turns: true)
  rescue StandardError => e
    ctx.log.warn("mcp_sign_in_failed", server: server.name, error: e.class.name)
    ctx.card(title: "Sign-in to #{server.name} failed", body: "chi's sign-in broke (#{e.class.name}); the debug log has it",
             level: :warn, between_turns: true)
  end

  # Kept: the server connects as a lazy start does (handshake, tools/list,
  # the cache), with spawn directly when its service already runs (a 401
  # met during a call, a sign-out), then the flow's card says so.
  def signed_in(server, card_id, ctx)
    server.token.forget
    begin
      reconnect(server, ctx)
      count = offered(server).size
      ctx.card(id: card_id, title: "Signed in to #{server.name}", body: "#{count} tool#{"s" unless count == 1}, ready to use.",
               between_turns: true)
    rescue StandardError => e
      if needs_sign_in?(server, e)
        signed_out(server, ctx, e)
        return
      end

      ctx.log.warn("mcp_server_failed", server: server.name, error: e.class.name, msg: e.message, signed_in: true)
      ctx.card(id: card_id, title: "Signed in, but #{server.name} didn't connect", body: e.message, level: :warn,
               between_turns: true)
    end
  end

  # Connect a server that has a sign-in now (spawn when its service
  # already runs, else its first start), then it runs; its "needs sign-in"
  # card loses its button (a later refusal shows it again).
  def reconnect(server, ctx)
    @restart.synchronize do
      if server.service.state == :running
        old = server.client
        spawn(server, ctx, cancelled: @sign_in_cancel)
        old.close unless old.equal?(server.client)
      else
        server.service.value
      end
      @sign_in_lock.synchronize do
        server.state = :running
        server.error = nil
      end
    end
    publish
    return unless @sign_in_lock.synchronize { server.card_shown.tap { server.card_shown = false } }

    ctx.card(id: "mcp-sign-in-#{server.name}", title: "#{server.name} needs sign-in", body: "Signed in since.", between_turns: true)
  end

  # A server that needs sign-in, signed in to meanwhile from another
  # session (the kept token, read again): connected now. False when there
  # is no kept token, or it doesn't connect.
  def signed_in_elsewhere?(server, ctx)
    return false unless server.state == :needs_sign_in && server.token.respond_to?(:kept)

    server.token.forget
    kept = kept_digest(server)
    return false if kept.nil? || kept == server.refused

    reconnect(server, ctx)
    ctx.log.info("mcp_signed_in_elsewhere", server: server.name)
    true
  rescue StandardError => e
    server.refused = kept_digest(server) # what it holds after a renew, too: not tried again
    ctx.log.warn("mcp_server_failed", server: server.name, error: e.class.name, msg: e.message, signed_in_elsewhere: true)
    false
  end

  # 16 hex of the SHA-256 of the kept access token, nil without one.
  def kept_digest(server)
    kept = server.token.respond_to?(:kept) && server.token.kept
    kept ? Digest::SHA256.hexdigest(kept["access_token"])[0, 16] : nil
  rescue StandardError
    nil
  end

  # Whether the kept sign-in is newer than the token +error+ refused (or,
  # none sent, whether there is one now): another session or a login
  # signed in after the request went out.
  def newer_sign_in?(server, error)
    kept = server.token.respond_to?(:kept) && server.token.kept
    return false unless kept

    error.sent_digest.nil? || Digest::SHA256.hexdigest(kept["access_token"])[0, 16] != error.sent_digest
  rescue StandardError
    false
  end

  # /mcp logout NAME: the kept token goes (the provider's revocation asked,
  # best effort), the client closes, the server needs sign-in. chi's
  # registration with the provider stays.
  def logout(name, ctx)
    refusal = sign_in_refusal(name)
    return refusal if refusal

    server = @servers.find { |s| s.name == name }
    kept = server.token.kept
    ctx.secrets.delete(server.token.name)
    server.token.forget
    OAuth.revoke(ctx.http, kept, log: ->(event, **fields) { ctx.log.info("mcp_#{event}", server: name, **fields) }) if kept
    server.client&.close
    server.state = :needs_sign_in
    publish
    "Signed out of #{name}."
  rescue Samagotchi::Plugin::Secrets::Unavailable, Samagotchi::Plugin::Secrets::Busy => e
    "#{name}'s sign-in wasn't forgotten: #{e.message}"
  end

  # Whether +error+ means the server wants a sign-in: a 401 from one that signs in.
  def needs_sign_in?(server, error) = server.signs_in && error.is_a?(HttpClient::Refused) && error.status == 401

  # The server needs sign-in: its state (said once), its card, and the
  # line its call answers.
  # Nil when +error+ (the 401) was for an older token than the kept one: the
  # state stays, the next request sends the new token.
  def signed_out(server, ctx, error = nil)
    if error && newer_sign_in?(server, error)
      server.token.forget
      return nil
    end

    first = @sign_in_lock.synchronize { server.state == :needs_sign_in ? false : (server.state = :needs_sign_in) }
    if first
      server.refused = kept_digest(server)
      server.error = nil
      publish
      ctx.log.info("mcp_needs_sign_in", server: server.name)
    end
    offer_sign_in(server, ctx)
    "Error: #{sign_in_line(server, ctx.turn_author)}"
  end

  # What a call of a server that needs sign-in answers: the owner's
  # command, or (a participant's turn) who signs in, no command.
  def sign_in_line(server, author = nil)
    return "#{server.name} needs sign-in: the session's owner signs in" if author

    "#{server.name} needs sign-in: the user runs /mcp login #{server.name}"
  end

  # The "needs sign-in" card, once per server per worker, never a turn's;
  # none on a one-shot; on a participant's turn held for the owner's next
  # turn end or command.
  def offer_sign_in(server, ctx)
    return if ctx.frontend == :one_shot

    if ctx.turn_author
      @sign_in_lock.synchronize { @held_cards << server.name unless @held_cards.include?(server.name) }
      return
    end
    first = @sign_in_lock.synchronize { server.card_shown ? false : (server.card_shown = true) }
    return unless first

    ctx.card(id: "mcp-sign-in-#{server.name}", title: "#{server.name} needs sign-in",
             body: "The server asks chi to sign in. Sign in opens its provider's page in your browser.",
             actions: [{ label: "Sign in", command: "/mcp login #{server.name}" }], between_turns: true)
  end

  def show_held_cards(ctx)
    names = @sign_in_lock.synchronize { @held_cards.slice!(0..) }
    names.each do |name|
      server = @servers.find { |s| s.name == name }
      offer_sign_in(server, ctx) if server&.state == :needs_sign_in
    end
  end

  # chi's client document's address (bundles: mcp: client_metadata_url:,
  # else CLIENT_METADATA_URL): an https address with a path, else nil
  # (false: none, never a CIMD client_id).
  def client_metadata_url
    value = @settings.fetch("client_metadata_url", CLIENT_METADATA_URL)
    return nil if value == false

    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty? && uri.path.to_s.length > 1 && uri.userinfo.nil? ? value.to_s : nil
  rescue URI::Error
    nil
  end

  # The service's stop: the waiting sign-ins end (core stops their flows
  # too), their threads get a moment to put their cards right.
  def stop_sign_ins
    @sign_in_cancel.cancel!
    threads = @sign_in_lock.synchronize { @sign_ins.values }
    threads.each { |thread| thread.join(2) }
  end

  # A remote server's token object: OAuth::Token for one that signs in
  # (with this chi's ctx.secrets), else the static one.
  def token_of(server, ctx)
    return token_lookup(server) unless server.signs_in && ctx.respond_to?(:secrets)

    oauth = server.oauth.is_a?(Hash) ? server.oauth : {}
    variable = oauth["client_secret_env"]
    client = oauth["client_id"] ? { id: oauth["client_id"], issuer: oauth["issuer"] } : nil
    OAuth::Token.new(secrets: ctx.secrets, resource: URI.parse(server.url).query ? nil : OAuth.canonical(server.url),
                     http: ctx.http, client: client, client_secret: -> { variable && env_value(server, variable) },
                     log: ->(event, **fields) { ctx.log.info("mcp_#{event}", server: server.name, **fields) })
  end
end
