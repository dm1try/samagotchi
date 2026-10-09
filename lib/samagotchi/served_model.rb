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

    # The host whose hosts.<name>.models.<id>.served names +served+ for
    # +target+'s model (a gateway's round-robin targets): not a mismatch to
    # warn about. nil when none does.
    # @param target [HostRegistry::ModelTarget]
    # @return [String, nil]
    def expected_by(target, served)
      target.entry.name if target.entry.models&.dig(target.bare_model.to_s.strip.downcase)&.serves?(served)
    end

    # The separators a provider uses when it decorates a model name: a tag
    # (`qwen3:latest`), a date or quant suffix (`gpt-4o-2024-08-06`), an
    # owner (`@org/name`) or a path (`meta-llama/Llama-3`). Anything else
    # after the name is a different model (`gpt-4` is not `gpt-4o`).
    EXTENSION_SEPARATORS = [":", "-", "@", "/"].freeze

    # Whether +served+ is another model than +asked+. Names that are equal
    # (any case), or where one extends the other at a tag/date/owner
    # separator (a provider dropping `:free`, or adding a date), are the
    # same model; unknown names never differ.
    def differs?(asked, served)
      asked = asked.to_s.strip.downcase
      served = served.to_s.strip.downcase
      return false if asked.empty? || served.empty?
      return false if asked == served

      shorter, longer = asked.length <= served.length ? [asked, served] : [served, asked]
      return true unless longer.start_with?(shorter)

      !longer[shorter.length..].start_with?(*EXTENSION_SEPARATORS)
    end
  end
end
