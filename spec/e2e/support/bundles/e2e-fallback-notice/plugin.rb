# frozen_string_literal: true

# The e2e suite's notices after an answer that says E2E_FALLBACK: one
# marked fallback_for: :display (a web page that renders markdown leaves it
# out) and a plain one (every UI shows it), for the fallback_notice scenario.
class Plugin
  def register(chi)
    chi.on(:after_turn) do |event, ctx|
      answer = Array(event[:messages]).reverse.find { |m| (m[:role] || m["role"]).to_s == "model" }
      next unless answer && (answer[:content] || answer["content"]).to_s.include?("E2E_FALLBACK")

      ctx.notify("e2e fallback line", fallback_for: :display)
      ctx.notify("e2e plain line")
    end
  end
end
