# frozen_string_literal: true

# The e2e suite's annotation action: an "E2E check" pill in the selection
# bar fills the composer with /e2e-check quote and the quote; the command
# echoes what it got, for the annotate scenario.
class Plugin
  def register(chi)
    chi.command "/e2e-check", "echo what an annotation action sends" do |args, _ctx|
      "checked: #{args}"
    end
    chi.annotation "E2E check", command: "/e2e-check quote"
  end
end
