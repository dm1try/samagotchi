module Samagotchi
  module SessionInbox
    delivery = File.expand_path("session_inbox_delivery", __dir__)
    %i[Dispatch Head Resolved].each { |name| autoload name, delivery }

    def self.deliver(kind) = Dispatch.deliver(kind)
  end
end
