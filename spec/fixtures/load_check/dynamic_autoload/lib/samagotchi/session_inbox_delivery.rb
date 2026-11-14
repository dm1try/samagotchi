module Samagotchi
  module SessionInbox
    Dispatch = Data.define(:kind)
    Head = Data.define(:kind, :target)
    Resolved = Data.define(:kind, :target, :session)
  end
end
