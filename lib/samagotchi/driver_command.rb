# frozen_string_literal: true

require_relative "agent_caller"
require_relative "client_id"
require_relative "session"

module Samagotchi
  # /driver, the agent that drives this session (Session#driver): with no
  # argument, who it is; `/driver NAME` names the agent NAME (agent:NAME),
  # `/driver none` drops it, saved at once. An agent's messages into a
  # session it drives are as chi send's were (no header, never counted
  # toward session.max_wakes); any other agent's are a visitor's (Visitor).
  # Naming one is the user's at a UI (+user_ui+: an attached TUI, the web):
  # from chi send, an agent or anyone else it is refused.
  class DriverCommand
    NAME = "/driver"
    USAGE = "usage: #{NAME} [NAME|none] (NAME: lowercase letters, digits, - and _)".freeze
    REFUSED = "naming this session's driver is the user's: #{NAME} in a chi terminal or the web " \
              "(not chi send or an agent)".freeze
    NONE = "none"

    # @param engine [Engine] #session
    # @param save [#call] saves the session after a change
    def initialize(engine:, save:)
      @engine = engine
      @save = save
    end

    # @param args [String] what follows /driver
    # @param user_ui [Boolean] a user at a UI typed it
    # @return [Array(String, Boolean, Symbol)] the reply, whether the
    #   driver changed, and :ok or :error
    def run(args, user_ui:)
      session = @engine.session or return [Session::NONE_YET, false, :error]
      words = args.to_s.split
      return [listing(session), false, :ok] if words.empty?
      return [USAGE, false, :error] if words.size > 1
      return [REFUSED, false, :error] unless user_ui

      driver = driver_for(words.first)
      return [USAGE, false, :error] if driver == :invalid
      return ["#{listing(session)}\n(no change)", false, :ok] if driver == session.driver

      session.driver = driver
      @save.call(session)
      [listing(session), true, :ok]
    end

    private

    # nil for none, agent:<name> for a name, :invalid for anything else.
    def driver_for(word)
      return nil if word.downcase == NONE

      name = AgentCaller.clean(word)
      name ? ClientId.agent(name) : :invalid
    end

    # "driver: agent claude (its messages are as yours: no header, not
    # counted)" or "driver: none (every agent here is a visitor)".
    def listing(session)
      name = ClientId.agent_name(session.driver)
      return "driver: none (every agent's message here is a visitor's: one header line, counted toward session.max_wakes)" unless name

      "driver: agent #{name} (its messages go in as yours: no header line, not counted toward session.max_wakes)"
    end
  end
end
