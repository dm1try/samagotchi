# frozen_string_literal: true

module Samagotchi
  # A single redacted #inspect for the classes that hold the process
  # environment (@env, every API key) or the web token (@token, or a :token
  # key inside a Hash ivar, as Web::App's @lan): instead of dumping every
  # instance variable (which would print the keys), it shows the rest with
  # each value's own inspect and prints the others as [redacted]. A failing
  # spec, a debugger or an error message that inspects one of them used to
  # leak every key.
  module RedactedInspect
    # The instance variables never printed.
    REDACTED = %i[@env @token].freeze
    # The keys of a Hash ivar whose values are never printed; the rest of the
    # Hash is, so Web::App's @lan still shows its :ip.
    REDACTED_KEYS = %i[token].freeze

    # Stands in for a redacted Hash value: inspects as [redacted], unquoted.
    HIDDEN = Object.new.tap { |hidden| hidden.define_singleton_method(:inspect) { "[redacted]" } }.freeze

    def inspect
      body = instance_variables.map do |ivar|
        if REDACTED.include?(ivar)
          "#{ivar}=[redacted]"
        else
          "#{ivar}=#{redacted_value(instance_variable_get(ivar)).inspect}"
        end
      end.join(", ")
      "#<#{self.class.name} #{body}>"
    end

    # pp otherwise ignores inspect.
    def pretty_print(printer) = printer.text(inspect)

    private

    def redacted_value(value)
      return value unless value.is_a?(Hash) && REDACTED_KEYS.any? { |key| value.key?(key) }

      value.to_h { |key, item| [key, REDACTED_KEYS.include?(key) ? HIDDEN : item] }
    end
  end
end
