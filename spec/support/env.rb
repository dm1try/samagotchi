# frozen_string_literal: true

# Set ENV for the block and put the previous values back after it (a nil
# value unsets the variable). Included in every example group by spec_helper.
#
#   with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run }
module SpecEnv
  def with_env(vars)
    saved = vars.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved&.each { |key, value| ENV[key] = value }
  end
end
