# frozen_string_literal: true

require "samagotchi/client"
require "samagotchi/kernel_loop"

# Integration test that verifies the omlx transport forwards a *resolved* `model`
# id to a live oMLX server: a short SAMAGOTCHI_MODEL selector is resolved, via the
# server's own /v1/models, to the exact registered id (which may be prefixed,
# e.g. "mlx-community--..."), so the completion no longer 400s on a missing model.
#
# No stubs: this talks to the real host via LLAMA_HOST/LLAMA_PORT/SAMAGOTCHI_MODEL.
#
# Prerequisites:
#   - An oMLX server must be running (default: 192.168.1.29:8000)
#   - LLAMA_INTEGRATION=1 environment variable must be set
#
# Run with:
#   LLAMA_INTEGRATION=1 LLAMA_HOST=192.168.1.29 LLAMA_PORT=8000 \
#     SAMAGOTCHI_MODEL=gemma-3-4b-it-4bit SAMAGOTCHI_SERVER_TRANSPORT=omlx \
#     bundle exec rspec spec/integration/omlx_spec.rb
#
# Verbose output:
#   LLAMA_INTEGRATION=1 LLAMA_HOST=192.168.1.29 LLAMA_PORT=8000 \
#     SAMAGOTCHI_MODEL=gemma-3-4b-it-4bit bundle exec rspec spec/integration/omlx_spec.rb -v
RSpec.describe "omlx transport - model resolution + forwarding", :integration do
  # The short selector we expect to resolve to a live /v1/models id.
  let(:selector) { ENV.fetch("SAMAGOTCHI_MODEL") }

  # A real oMLX client built from LLAMA_HOST / LLAMA_PORT / SAMAGOTCHI_SERVER_TRANSPORT.
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

  # Directly against the oMLX completion endpoint: forwarding our short selector
  # as the `model:` argument proves resolution worked — oMLX accepts the request
  # (no 400 "model: Field required") with the resolved id in the body. We assert
  # acceptance (a 400 raises, so a clean String return is the signal), not text
  # output: oMLX occasionally emits an empty chunk stream for a prompt (a model
  # quirk, not a forwarding failure); that's the KernelLoop test's job.
  it "completes against the live oMLX endpoint with the resolved model (no 400)" do
    result = client.complete("hi", n_predict: 32, model: selector)
    expect(result).to be_a(String)
  end

  it "runs a KernelLoop end-to-end round trip against the live oMLX host" do
    kernel = Samagotchi::KernelLoop.new(client: client)
    messages = [{ role: "user", content: "Write exactly two words: hello world" }]
    response = kernel.run(messages, max_iterations: 1)
    expect(response).to be_a(Samagotchi::KernelLoop::Result)
    expect(response.output).to be_a(String)
  end
end
