# frozen_string_literal: true

# The plugin file (spec fixture): its class body includes helpers.rb's
# Helpers; /parts calls shout.rb's Shout when it runs.
class Plugin
  include Helpers

  def register(chi)
    chi.command "/parts", "greet through the plugin's parts" do |args, _ctx|
      Shout.new.say(greeting(args.empty? ? "parts" : args))
    end
  end
end
