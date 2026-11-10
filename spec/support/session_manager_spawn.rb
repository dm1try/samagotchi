# frozen_string_literal: true

require_relative "../../lib/samagotchi/client_id"

module SpecSessionManagerSpawn
  def spawn_session_for_spec(manager = Samagotchi::SessionManager, **options)
    options[:client_id] = Samagotchi::ClientId::CLI_SEND unless options.key?(:client_id)
    manager.spawn_session(**options)
  end
end
