require "samagotchi/log"

module Samagotchi
  class UsesLog
    def tell = Log.info("hi")
  end
end
