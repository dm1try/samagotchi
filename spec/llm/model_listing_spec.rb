# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/model_listing"

RSpec.describe Samagotchi::LLM::ModelListing do
  it "backs off after a failed list without caching it, then retries after the backoff" do
    fetches = 0
    adapter_class = Class.new do
      include Samagotchi::LLM::ModelListing

      def initialize(models_ttl:, &fetch)
        @host_name = "box"
        @base_url = "https://example.test"
        @fetch = fetch
        init_model_listing(models_ttl)
      end

      def list_models = @fetch.call
    end
    adapter = adapter_class.new(models_ttl: 300) do
      fetches += 1
      raise IOError, "down" if fetches == 1

      [Samagotchi::LLM::ModelInfo.new(id: "m", context_window: 4096, supports_tools: nil, raw: {})]
    end
    now = 10.0
    allow(adapter).to receive(:monotonic) { now }

    expect(adapter.context_window(model: "m")).to be_nil
    now += 59
    expect(adapter.image_input(model: "m")).to be_nil
    expect(fetches).to eq(1)
    expect(adapter.instance_variable_get(:@models)).to be_nil
    expect(adapter.instance_variable_get(:@models_at)).to be_nil

    now += 2
    expect(adapter.context_window(model: "m")).to eq(4096)
    expect(fetches).to eq(2)
  end
end
