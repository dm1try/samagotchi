# frozen_string_literal: true

# The first part (spec fixture): what the later files' class bodies use.
class Plugin
  # A module the plugin class includes in its body.
  module Helpers
    def greeting(who) = "hello, #{who}"
  end

  # A superclass shout.rb's class body names.
  class Speaker
    def say(text) = text
  end
end
