# The http-echo bundle (spec fixture, docs/plugins.md "Calling services"):
# one tool that asks a local HTTP service and returns its answer.
class Plugin
  def initialize(settings)
    @url = settings.fetch("url", "http://127.0.0.1:9000/ask")
  end

  def register(chi)
    chi.tool "ask_service", "Ask the local question service and return its answer",
             params: { question: { type: "string", description: "What to ask", required: true } },
             label: "asking" do |args, ctx|
      res = ctx.http.post_json(@url, { question: args["question"] }, timeout: 5)
      if res.ok?
        res.json["answer"].to_s
      else
        ctx.log.warn(:ask_failed, status: res.status)
        "the service answered #{res.status}"
      end
    rescue Samagotchi::Plugin::HttpError => e
      "the service is not reachable: #{e.message}"
    end
  end
end
