# frozen_string_literal: true

module Samagotchi
  # A model a host serves, declared under hosts.<name>.models: whatever the
  # host's /v1/models says (a gateway's round-robin ids it never lists). A
  # declared id is known on its host: no "doesn't list" warning, no re-list,
  # and a bare id routes there as if the host listed it
  # (HostRegistry#host_for_model).
  #
  # id: the id as written (keys are matched downcased).
  HostModel = Data.define(:id) do
    # hosts.<name>.models as written: a map of ids (each nil or a map), or
    # a plain list of ids. Anything else warns once and is skipped.
    # @param raw [Hash, Array, nil]
    # @param host_name [String] for the warnings
    # @return [Hash{String => HostModel}] by downcased id, in written order
    def self.parse_map(raw, host_name)
      return {} if raw.nil?

      where = "hosts.#{host_name}.models"
      pairs = case raw
              when Hash then raw.to_a
              when Array then raw.map { |id| [id, nil] }
              else
                ConfigFile.warn_once "Warning: #{where} must be a map or a list of model ids; ignored"
                return {}
              end
      pairs.each_with_object({}) do |(id, entry), models|
        id = id.to_s.strip if id.is_a?(String) || id.is_a?(Symbol)
        unless id.is_a?(String) && !id.empty?
          ConfigFile.warn_once "Warning: #{where}: #{id.inspect} is not a model id; ignored"
          next
        end
        unless entry.nil? || entry.is_a?(Hash)
          ConfigFile.warn_once "Warning: #{where}.#{id} must be empty or a mapping; ignored"
          next
        end
        models[id.downcase] ||= new(id: id)
      end
    end

    # The entry as written back to config (SAMAGOTCHI_HOSTS_JSON for
    # workers): nil for a bare id.
    def to_config = nil
  end
end
