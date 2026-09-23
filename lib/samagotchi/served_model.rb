# frozen_string_literal: true

module Samagotchi
  # The model a server says it served, which can differ from the name asked
  # for: a single-model llama.cpp answers any name with the model it loaded.
  # Servers name it in /props (llama.cpp's model_alias, before any turn) and
  # in each response's `model` field (see the loops' :generation_completed).
  module ServedModel
    module_function

    # @param props [Client::ServerProps, nil] a /props probe
    # @return [String, nil] llama.cpp's model_alias when the probe answered
    def from_props(props)
      return nil unless props&.answered? && props.body.is_a?(Hash)

      name = props.body["model_alias"]
      name.is_a?(String) && !name.strip.empty? ? name : nil
    end

    # Whether +served+ is another model than +asked+. Names that are equal
    # (any case) or where one extends the other (a provider dropping
    # `:free`, or adding a date) are the same model; unknown names never
    # differ.
    def differs?(asked, served)
      asked = asked.to_s.strip.downcase
      served = served.to_s.strip.downcase
      return false if asked.empty? || served.empty?

      !(asked.start_with?(served) || served.start_with?(asked))
    end
  end
end
