# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/mcp_plugin_files"

# The mcp bundle's cache key for a remote server (Plugin#resolve_url): the
# digest of its url, headers and bearer_token_env, and of its oauth: map only
# when one is set. Fixed values: a server without oauth: must digest
# byte-for-byte as before sign-in came, or every remote user's cache reads as
# "config changed" (a turn-blocking first run).
RSpec.describe "The mcp bundle's remote server digest" do
  let(:plugin_module) { McpPluginFiles.load_module }
  let(:plugin) { plugin_module::Plugin.new({}) }

  def digest(config)
    server = plugin_module::Plugin::Server.new(name: "fake", config: config, state: :starting, tools: [])
    plugin.send(:resolve_url, server)
    server.digest
  end

  it "is unchanged for a server without oauth:" do
    expect(digest({ "url" => "https://mcp.example.com/mcp", "headers" => { "X-A" => "1" }, "bearer_token_env" => "T" }))
      .to eq("416d19cad3a8949935bd5c757a8bfbcd47330d90b1b4928b35c029c81982b1c9")
    expect(digest({ "url" => "https://mcp.example.com/mcp" }))
      .to eq("374fd20da60192767974d50d862700ec69d20d591edfed579570b6a5312913c0")
  end

  it "takes oauth: in when it is set, whatever its keys' order" do
    plain = digest({ "url" => "https://mcp.example.com/mcp" })
    one = digest({ "url" => "https://mcp.example.com/mcp", "oauth" => { "client_id" => "c", "issuer" => "https://id.example" } })
    other = digest({ "url" => "https://mcp.example.com/mcp", "oauth" => { "issuer" => "https://id.example", "client_id" => "c" } })

    expect(one).not_to eq(plain)
    expect(one).to eq(other)
    expect(digest({ "url" => "https://mcp.example.com/mcp", "oauth" => {} })).not_to eq(plain)
  end

  it "keeps the oauth: map out of Server#inspect" do
    server = plugin_module::Plugin::Server.new(name: "fake", config: { "url" => "https://mcp.example.com/mcp",
                                                                       "oauth" => { "client_id" => "CLIENT-ID-1" } },
                                               state: :starting, tools: [])
    plugin.send(:resolve_url, server)

    expect(server.inspect).not_to include("CLIENT-ID-1")
  end
end
