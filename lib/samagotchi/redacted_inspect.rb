# frozen_string_literal: true

module Samagotchi
  # A single redacted #inspect for the classes that hold the process
  # environment (@env, every API key) or the web token (@token): instead of
  # dumping every instance variable (which would print the keys), it shows the
  # rest with each value's own inspect and prints the others as [redacted]. A
  # failing spec, a debugger or an error message that inspects one of them used
  # to leak every key.
  module RedactedInspect
    # The instance variables never printed.
    REDACTED = %i[@env @token].freeze

    def inspect
      body = instance_variables.map do |ivar|
        if REDACTED.include?(ivar)
          "#{ivar}=[redacted]"
        else
          "#{ivar}=#{instance_variable_get(ivar).inspect}"
        end
      end.join(", ")
      "#<#{self.class.name} #{body}>"
    end

    # pp otherwise ignores inspect.
    def pretty_print(printer) = printer.text(inspect)
  end
end
