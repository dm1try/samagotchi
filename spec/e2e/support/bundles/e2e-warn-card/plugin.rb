# frozen_string_literal: true

# The e2e suite's warn card: a read of e2e-warn-card.txt shows a :warn card
# in the running step (the turn goes on), for the warn_card scenario.
class Plugin
  def register(chi)
    chi.on(:before_tool_call) do |event, ctx|
      next unless event[:call].to_s.include?("e2e-warn-card.txt")

      ctx.card(title: "e2e warn card", body: "a warning mid-turn", level: :warn)
    end
  end
end
