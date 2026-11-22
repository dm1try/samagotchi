# frozen_string_literal: true

require_relative "client_id"
require_relative "session_paths"

module Samagotchi
  # Who an agent's message goes in as: the one seat that names the client
  # id chi send, Ask#agent_line (chi web's ask, the MCP tools on this
  # machine) and the MCP tools to another machine send a message with. An
  # agent is named by --as, else by the marker its process carries
  # (Guardrails::ParentApprovals::AGENT_MARKERS); none is the owner (a pipe
  # alone is not a marker: the owner's own script stays the owner's). The id
  # is self-declared, as chi send's is: a convention for an honest agent,
  # not a security boundary. No Engine, so a command loads it cheaply.
  module AgentCaller
    # A name: lowercase letters, digits, - and _ (ClientId::AGENT_NAME_MAX).
    NAME = /\A[a-z0-9_-]{1,#{ClientId::AGENT_NAME_MAX}}\z/
    # The name a marker gives when its value is not one.
    FALLBACK = "agent"
    # chi's own marker (execute and tasks set it, the model can't change it):
    # its session's first 8 characters, or "chi" for a run with no session.
    # Guardrails::ParentApprovals::PARENT_SESSION_ENV's (a spec keeps them
    # the same: that file is too big a load for chi send's start).
    PARENT_SESSION = "SAMAGOTCHI_PARENT_SESSION"
    # The vendors' markers, in order, and the name each gives (nil: its
    # value, cleaned).
    VENDOR_MARKERS = [%w[CLAUDECODE claude], %w[CODEX_THREAD_ID codex], ["AI_AGENT", nil]].freeze

    module_function

    # +name+ as an agent's name (lowercased), or nil when it isn't one: the
    # name reaches a header the model reads, so it is never free text.
    def clean(name)
      text = name.to_s.strip.downcase
      text.match?(NAME) ? text : nil
    end

    # The caller's name, or nil for the owner: chi's own marker first, even
    # over +as+ (a worker inherits its spawner's environment, so a chi
    # session's own model may carry CLAUDECODE too); then +as+; then the
    # vendors' markers.
    # @param as [String, nil] chi send --as's (cleaned before: #clean)
    def name(env: ENV, as: nil)
      parent = env.fetch(PARENT_SESSION, "").to_s.strip
      return parent_name(parent) unless parent.empty?
      return as unless as.to_s.empty?

      VENDOR_MARKERS.each do |key, given|
        value = env.fetch(key, "").to_s.strip
        next if value.empty?

        return given || clean(value) || FALLBACK
      end
      nil
    end

    # Whether chi's own marker names this process (chi send --as is ignored
    # there).
    def inside_chi?(env: ENV) = !env.fetch(PARENT_SESSION, "").to_s.strip.empty?

    # The client id a message from this caller goes in as: an agent's
    # (agent:<name>), or chi send's, the owner's, with no name.
    # @param name [String, nil] the agent's name (#name)
    # @return [String]
    def send_id(name: nil)
      name.to_s.empty? ? ClientId::CLI_SEND : ClientId.agent(name)
    end

    # A /continue yes from +id+ (a parent line, ClientId.parent_line?) goes
    # in as chi answer's, held to guardrails.parent_answers; any other id as
    # given.
    def continue_id(id) = ClientId.parent_line?(id) ? ClientId::CLI_ANSWER : id

    # "chi" (Tools::Builtins.parent_env's, a run with no session) or
    # anything not an id: "chi".
    def parent_name(value)
      return "chi" if value == "chi" || !SessionPaths.valid_id?(value)

      clean("chi-#{value[0, 8]}") || "chi"
    end
    private_class_method :parent_name
  end
end
