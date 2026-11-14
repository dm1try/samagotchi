require "samagotchi/session_inbox"

module Samagotchi
  class Broadcast
    def head(kind, target) = SessionInbox::Head.new(kind, target)
  end
end
