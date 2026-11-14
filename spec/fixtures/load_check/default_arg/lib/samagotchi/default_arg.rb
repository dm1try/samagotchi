module Samagotchi
  class DefaultArg
    def call(target = Sink.new) = target
  end

  Sink = Data.define(:name)
end
