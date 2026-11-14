module Samagotchi
  ConfigFile = Data.define(:path)

  class Config
    def file = ConfigFile.new("x")
  end
end
