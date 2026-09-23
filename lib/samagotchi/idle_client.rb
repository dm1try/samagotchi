# frozen_string_literal: true

require "json"
require "ruby_llm"

module Samagotchi
  # Standalone summarizer for the idle session-recap feature.
  #
  # Talks to a local llama.cpp server (an OpenAI-compatible /chat/completions
  # endpoint) via the gem's Connection — it is NEVER wired into the Engine's
  # kernel/backend, so it shares no engine concurrency. The Engine's idle
  # detector only snapshots session.messages and calls #summarize; this object
  # owns the HTTP boundary and is fully decoupled (configurable base_url + model).
  #
  # A dummy API key satisfies the gem's `configured?` check for a local endpoint
  # (no real key needed); the request targets /chat/completions, NOT
  # /completions (a raw completions endpoint loops on gemma think tokens).
  #
  # #summarize raises SummarizeError on any failure; the idle detector isolates
  # that so a failed recap never breaks the active session.
  class IdleClient
    # Raised when summarization fails (server down, timeout, malformed body…).
    class SummarizeError < StandardError; end

    DEFAULT_MODEL = "gemma4-small"
    DUMMY_API_KEY = "sk-local-dummy"
    DEFAULT_TIMEOUT_SECONDS = 30.0
    # 2-4 sentences need ~100 tokens with thinking off; the rest is headroom.
    MAX_TOKENS = 512

    # @param timeout [Numeric] HTTP request timeout. Kept to the recap's own
    #   wait budget (not the chat's global request_timeout) so an abandoned
    #   summarize thread can't outlive the recap attempt by minutes.
    def initialize(model: DEFAULT_MODEL, base_url: nil, api_key: DUMMY_API_KEY, timeout: DEFAULT_TIMEOUT_SECONDS)
      @model = model
      @base_url = base_url.to_s.chomp("/") if base_url
      @api_key = api_key
      @timeout = timeout
    end

    THINK_RE = /<\|think\|.*?\|think\|>/m
    LITERAL_THINK_RE = /\[\[SAMAGOTCHI_LITERAL_THINK_OPEN\]\].*?\[\[SAMAGOTCHI_LITERAL_THINK_CLOSE\]\]/m

    # Strip thinking blocks (gemma <|think|>…, qwen prompt literals) and
    # collapse the blank lines they leave. Shared with IdleRecap's
    # transcript filter.
    def self.strip_thinking(text)
      text.to_s
          .gsub(THINK_RE, "")
          .gsub(LITERAL_THINK_RE, "")
          .gsub(/\n\n+/, "\n")
          .strip
    end

    # +text+ up to its last sentence end (. ! ? plus closing quotes or
    # brackets, then whitespace or the end), or "" when none finished.
    def self.full_sentences(text)
      text.to_s[/\A.*[.!?]["')\]`*]*(?=\s|\z)/m].to_s
    end

    # Summarize an already-built recap prompt. Returns the cleaned prose, or
    # nil when there is nothing to summarize. Any failure raises
    # SummarizeError (the caller isolates it).
    def summarize(prompt)
      body = prompt.to_s.strip
      return nil if body.empty?

      content = generate(body)
      cleaned = content.to_s.strip
      cleaned.empty? ? nil : cleaned
    rescue SummarizeError
      raise
    rescue StandardError => e
      raise SummarizeError, "recap summarization failed: #{e.class}: #{e.message}"
    end

    private

    # One-shot POST to the local /chat/completions endpoint. Returns the raw
    # assistant content string. Raises SummarizeError when the server responds
    # with no parseable assistant message (nil content) or empty content;
    # returns nil when the server responded but gave empty content after stripping
    # (nothing to summarize).
    def generate(prompt)
      provider = gem_provider
      body = {
        model: @model,
        temperature: 0.0,
        max_tokens: MAX_TOKENS,
        messages: [{ role: "user", content: prompt }],
        # A reasoning model otherwise spends the budget thinking and the
        # recap stops mid-sentence. Templates without the switch ignore it.
        chat_template_kwargs: { enable_thinking: false }
      }
      base = provider.api_base.to_s
      base = base.chomp("/") if base.end_with?("/")
      url = "#{base}/chat/completions"
      response = provider.connection.post(url, body)
      content = parse_content(response)
      # No parseable message, or message exists but both content and reasoning_content are empty
      raise SummarizeError, "server returned no parseable assistant content" if content.nil? || content == :empty_content
      # Content is empty after stripping thinking tokens (whitespace only)
      return nil if content.empty?

      content
    end

    # Lazily build a dummy-keyed OpenAI provider pointed at base_url. The dummy
    # key satisfies `configured?` for the local endpoint (a non-nil key is
    # enough; we never route local traffic to OpenRouter).
    def gem_provider
      @gem_provider ||= RubyLLM::Providers::OpenAI.new(build_config)
    end

    def build_config
      config = RubyLLM::Configuration.new
      # A recap is best-effort: one short attempt, no retries. The idle job
      # tries again after the next activity, never on its own.
      config.request_timeout = @timeout
      config.max_retries = 0
      # Set our local endpoint settings
      config.openai_api_key = @api_key
      config.openai_api_base = @base_url if @base_url
      config
    end

    # choices[0].message.content — falls back to reasoning_content when the
    # model outputs think tokens into a separate field (e.g. Qwen3.6).
    # Strips thinking tokens (e.g., <|think|>...</think|> or [[SAMAGOTCHI_LITERAL_THINK_OPEN]]...[[SAMAGOTCHI_LITERAL_THINK_CLOSE]])
    # from the content to return only the actual answer.
    # Returns:
    #   - String with the cleaned content if parseable and non-empty
    #   - :empty_content if message exists but content+reasoning_content are both empty
    #   - nil if no parseable message at all (no choices, no message)
    def parse_content(response)
      body = response.respond_to?(:body) ? response.body : response
      body = JSON.parse(body) if body.is_a?(String)
      message = body.is_a?(Hash) ? body.dig("choices", 0, "message") : nil
      return nil unless message.is_a?(Hash)

      content = message["content"]&.to_s || ""
      reasoning = message["reasoning_content"]&.to_s || ""

      # Both content and reasoning_content are explicitly empty strings
      # (not just whitespace) - this is a valid message with no actual content
      return :empty_content if content.empty? && reasoning.empty?

      # Prefer content, fall back to reasoning_content
      text = content.empty? ? reasoning : content
      # Strip thinking tokens that some models (Qwen, Gemma) include in content
      text = self.class.strip_thinking(text)
      # Cut off by max_tokens: keep the sentences that finished ("" if none).
      text = self.class.full_sentences(text) if body.dig("choices", 0, "finish_reason") == "length"
      text
    end

  end
end
