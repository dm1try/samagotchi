module Samagotchi
  class UsesSession
    def open = Session.load(1)
  end
end
