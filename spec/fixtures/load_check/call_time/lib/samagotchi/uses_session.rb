module Samagotchi
  class UsesSession
    def open = Session.load(1)

    def id = Session.current_id
  end
end
