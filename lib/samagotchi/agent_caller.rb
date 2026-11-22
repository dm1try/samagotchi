# frozen_string_literal: true

require_relative "client_id"

module Samagotchi
  # Who an agent's message goes in as: the one seat that names the client
  # id chi send, Ask#agent_line (chi web's ask, the MCP tools on this
  # machine) and the MCP tools to another machine send a message with. No
  # Engine, no requires beyond ClientId, so a command loads it cheaply.
  module AgentCaller
    module_function

    # The client id a message from this caller goes in as.
    # @param name [String, nil] the agent's name; nil: the owner's
    # @return [String]
    def send_id(name: nil)
      ClientId::CLI_SEND
    end
  end
end
