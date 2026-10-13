# frozen_string_literal: true

module Samagotchi
  # Where a side request goes (a recap, a plugin's ctx.ask_model, a
  # broadcast's triage): a model on a host's chat API, asked through its
  # own IdleClient (IdleClient.for), apart from the session's turns.
  # @!attribute base_url [String] the host's API base (HostEntry#api_base_url)
  # @!attribute api_key_env [String, nil] the variable holding its key
  # @!attribute model [String] the model id sent to the server
  # @!attribute label [String] the model as configured, for logs
  # @!attribute api [Symbol] the wire the side client talks (LLM::Adapters):
  #   a chat host's api, else :openai (a raw host's server, or a bare url)
  # @!attribute auth [Symbol, nil] the header its key goes in (the host's
  #   auth:, LLM::ApiKey::SCHEMES); nil: the api's own default
  IdleTarget = Data.define(:base_url, :api_key_env, :model, :label, :api, :auth) do
    def initialize(api: :openai, auth: nil, **) = super

    # The api a side request to +entry+ talks: a chat host's own, else the
    # OpenAI API (a raw host's llama.cpp serves /v1 too).
    def self.api_of(entry) = entry.chat? ? entry.api : :openai

    # A configured side model can't be resolved.
    # @!attribute reason [Symbol] :host_ref_unknown (no such host),
    #   :model_host_mismatch (the model names another host than host_ref)
    #   or :incomplete (no base_url or no model)
    class self::Unresolved < StandardError
      attr_reader :reason, :model, :host_ref, :named

      def initialize(reason, model: nil, host_ref: nil, named: nil)
        @reason = reason
        @model = model
        @host_ref = host_ref
        @named = named
        super("side model #{model.inspect} can't be resolved: #{reason}")
      end
    end

    # +name+ (a model ref) as a turn resolves it: its alias applied, its
    # host, or where a bare --model goes (HostRegistry#resolve, which may
    # list a host's models).
    # @param host_registry [HostRegistry]
    # @return [IdleTarget]
    def self.of_model(host_registry, name)
      resolved = host_registry.resolve(name)
      entry = resolved.entry
      new(base_url: entry.api_base_url, api_key_env: entry.api_key_env, model: resolved.bare_model,
          label: name.to_s.strip, api: api_of(entry), auth: entry.auth)
    end

    # A side model's settings (recap.*, broadcast.triage_*) as a target:
    # +base_url+ with +model+; +host_ref+ (a hosts: name) with +model+;
    # +model+ alone (its own host, its alias's, or where a bare --model
    # goes). Blank values count as unset.
    # @param host_registry [HostRegistry]
    # @return [IdleTarget, nil] nil when all three are unset (the caller
    #   picks its default)
    # @raise [Unresolved]
    def self.resolve(model:, host_ref:, base_url:, host_registry:)
      model, host_ref, base_url = [model, host_ref, base_url].map { |value| blank(value) }
      return nil if model.nil? && host_ref.nil? && base_url.nil?

      label = model.to_s
      parsed = model && host_registry.model_ref(model)
      return of_model(host_registry, model) unless host_named?(model: model, host_ref: host_ref, base_url: base_url,
                                                               host_registry: host_registry)

      host_ref ||= parsed.host_name if parsed && base_url.nil?
      api_key_env = nil
      api = :openai
      auth = nil
      if host_ref
        entry = host_registry.find_entry(host_ref)
        raise self::Unresolved.new(:host_ref_unknown, model: model, host_ref: host_ref) unless entry

        base_url = entry.api_base_url
        api_key_env = entry.api_key_env
        api = api_of(entry)
        auth = entry.auth
        named = parsed&.host_conflict || parsed&.host_name
        if named && named != entry.name
          raise self::Unresolved.new(:model_host_mismatch, model: model, host_ref: host_ref, named: named)
        end

        model = parsed.id if parsed
      elsif parsed && !parsed.host_name
        model = parsed.id
      end
      raise self::Unresolved.new(:incomplete, model: model, host_ref: host_ref) if blank(base_url).nil? || blank(model).nil?

      new(base_url: base_url.to_s.strip, api_key_env: api_key_env, model: model.to_s.strip, label: label.strip, api: api, auth: auth)
    end

    # Whether the settings fix a host (+base_url+, +host_ref+, or a model
    # ref naming one), so resolving them once holds; a model alone that
    # names none goes where a bare --model goes, which a host's model list
    # decides (resolve it at each request).
    def self.host_named?(model:, host_ref:, base_url:, host_registry:)
      return true if blank(base_url) || blank(host_ref)

      model = blank(model)
      !model.nil? && !host_registry.model_ref(model).host_name.nil?
    end

    def self.blank(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
    private_class_method :blank
  end
end
