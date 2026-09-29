# frozen_string_literal: true

# thinking.level off for the example (SAMAGOTCHI_THINKING_LEVEL): a Gemma
# prompt without the <|think|> token, a Qwen one with the empty thought.
RSpec.shared_context "thinking off" do
  around do |example|
    saved = ENV["SAMAGOTCHI_THINKING_LEVEL"]
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    example.run
  ensure
    saved.nil? ? ENV.delete("SAMAGOTCHI_THINKING_LEVEL") : ENV["SAMAGOTCHI_THINKING_LEVEL"] = saved
  end
end
