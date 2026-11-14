module Samagotchi
  class StdlibUser
    def parse(text) = JSON.parse(text)
    def point = Struct.new(:x)
    def error = JSON::ParserError
  end

  class Ordered < Comparable
  end
end
