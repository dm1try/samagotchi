# frozen_string_literal: true

require "samagotchi/client"
require "samagotchi/kernel_loop"

# Integration test that verifies the omlx transport forwards a *resolved* `model`
# id to a live oMLX server: a short SAMAGOTCHI_DEFAULT_MODEL selector is resolved, via the
# server's own /v1/models, to the exact registered id (which may be prefixed,
# e.g. "mlx-community--..."), so the completion no longer 400s on a missing model.
#
# No stubs: this talks to the real host via SAMAGOTCHI_SERVER_HOST/SAMAGOTCHI_SERVER_PORT/SAMAGOTCHI_DEFAULT_MODEL.
#
# Prerequisites:
#   - An oMLX server must be running (default: 192.0.2.10:8000)
#   - SAMAGOTCHI_INTEGRATION=1 environment variable must be set
#
# Run with:
#   SAMAGOTCHI_INTEGRATION=1 SAMAGOTCHI_SERVER_HOST=192.0.2.10 SAMAGOTCHI_SERVER_PORT=8000 \
#     SAMAGOTCHI_DEFAULT_MODEL=gemma-3-4b-it-4bit SAMAGOTCHI_SERVER_TRANSPORT=omlx \
#     bundle exec rspec spec/integration/omlx_spec.rb
#
# Verbose output:
#   SAMAGOTCHI_INTEGRATION=1 SAMAGOTCHI_SERVER_HOST=192.0.2.10 SAMAGOTCHI_SERVER_PORT=8000 \
#     SAMAGOTCHI_DEFAULT_MODEL=gemma-3-4b-it-4bit bundle exec rspec spec/integration/omlx_spec.rb -v
RSpec.describe "omlx transport - model resolution + forwarding", :integration do
  # The short selector we expect to resolve to a live /v1/models id.
  let(:selector) { ENV.fetch("SAMAGOTCHI_DEFAULT_MODEL") }

  # A real oMLX client built from SAMAGOTCHI_SERVER_HOST / SAMAGOTCHI_SERVER_PORT / SAMAGOTCHI_SERVER_TRANSPORT.
  let(:client) { Samagotchi::Client.new(transport: :omlx) }

  # The live /v1/models id list (array of hashes with an "id" key), fetched once.
  def live_model_ids
    client.list_models.map { |m| m.is_a?(Hash) ? m["id"] : m }.compact
  end

  # NOTE: resolve_omlx_model is private; used here to assert resolution directly.
  it "resolves a short selector to an id present in the live /v1/models list" do
    resolved = client.send(:resolve_omlx_model, selector)
    expect(resolved).to be_a(String)
    expect(resolved).not_to be_empty
    # Assert membership rather than a host-specific prefix (mlx-community--) so
    # the test stays correct against any oMLX deployment.
    expect(live_model_ids).to include(resolved)
  end

  # Directly against the oMLX completion endpoint: the resolved selector must be
  # a real /v1/models id (test #1 proves this) and the completed body must be
  # non-empty. A 400 "model: Field required" yields an error JSON body that
  # parse_stream_line skips, so complete() returns "" — a non-empty body is the
  # signal that the resolved model id was forwarded and oMLX accepted it.
  # oMLX can emit an empty stream for a given prompt (a model quirk, not a
  # forwarding failure), so we retry simple prompts until we land on a reply.
  it "returns a non-empty completion with the resolved model id (no 400)" do
    prompts = [
      "Reply with a single digit between 1 and 9.",
      "Reply with a single word that is also a colour.",
      "Reply with exactly one word: banana."
    ]
    reply = ""
    (0...prompts.size).each do |i|
      reply = client.complete(prompts[i], n_predict: 32, model: selector).to_s.strip
      break unless reply.empty?
    end
    expect(reply).not_to be_empty
  end

  it "runs a KernelLoop end-to-end round trip against the live oMLX host" do
    kernel = Samagotchi::KernelLoop.new(client: client)
    messages = [{ role: "user", content: "Write exactly two words: hello world" }]
    response = kernel.run(messages, max_iterations: 1)
    expect(response).to be_a(Samagotchi::LLM::ModelResult)
    expect(response.output).to be_a(String)
  end
end
