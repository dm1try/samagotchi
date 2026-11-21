# frozen_string_literal: true

# The second part (spec fixture): its class body needs helpers.rb's Speaker.
class Plugin
  class Shout < Speaker
    def say(text) = super.upcase
  end
end
