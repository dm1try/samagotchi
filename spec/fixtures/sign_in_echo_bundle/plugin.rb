# The sign-in-echo bundle (spec fixture, docs/plugins.md "Sign-in"):
# /echo-login sends you to a provider's sign-in page, keeps the code the
# browser brings back as a secret (it exchanges nothing), and the
# echo_token tool reads it back.
require "securerandom"
require "uri"

class Plugin
  def initialize(settings)
    @authorize = settings.fetch("authorize_url", "http://127.0.0.1:9100/authorize")
  end

  def register(chi)
    chi.command "/echo-login", "sign in to the echo provider" do |_args, ctx|
      state = SecureRandom.hex(16)
      flow = ctx.sign_in(title: "Sign in to Echo", button: "Open sign-in page", timeout: 300) do |redirect_uri|
        "#{@authorize}?#{URI.encode_www_form(redirect_uri: redirect_uri, state: state)}"
      end
      next "sign-in needs the web or a terminal" if flow.outcome == :stopped

      # flow.wait blocks: never on the command's thread.
      Thread.new do
        result = flow.wait
        if result && result["code"]
          ctx.secrets.update("echo") { result["code"] }
          ctx.card(id: flow.card_id, title: "Signed in to Echo", body: "The echo_token tool reads it.")
        end
      end
      nil
    end

    chi.tool "echo_token", "Read back the code the echo sign-in kept", params: {}, label: "reading" do |_args, ctx|
      code = ctx.secrets.get("echo")
      code ? "signed in: #{code}" : "not signed in (run /echo-login)"
    end
  end
end
