# frozen_string_literal: true

require "json"
require_relative "llm/openai_chat"

module Samagotchi
  # Standalone summarizer for the idle session-recap feature.
  #
  # Asks an OpenAI-compatible /chat/completions endpoint (the local llama.cpp,
  # or a recap host's) through its own OpenAIChat: one plain request, no
  # tools, no retries, its own timeout. It is NEVER wired into the Engine's
  # kernel/backend, so it shares no engine concurrency. The Engine's idle
  # detector only snapshots session.messages and calls #summarize; this object
  # owns the HTTP boundary and is fully decoupled (configurable base_url + model).
  #
  # The request targets /chat/completions, NOT /completions (a raw
  # completions endpoint loops on gemma think tokens).
  #
  # #summarize raises SummarizeError on any failure; the idle detector isolates
  # that so a failed recap never breaks the active session.
  class IdleClient
    # Raised when summarization fails (server down, timeout, malformed body…).
    class SummarizeError < StandardError; end

    # What #summarize returns: the recap text and the model that answered
    # (the server's name for it; nil when the reply names none). #to_s is
    # the text.
    Summary = Data.define(:text, :model) do
      def to_s = text
    end

    DEFAULT_MODEL = "gemma4-small"
    DEFAULT_TIMEOUT_SECONDS = 30.0
    # Up to 10 sentences (recap.sentences) need ~350 tokens with thinking off.
    MAX_TOKENS = 512

    # Request fields that turn thinking off. A reasoning model otherwise
    # spends the budget thinking and the recap stops mid-sentence.
    # - chat_template_kwargs.enable_thinking: the chat template's switch
    #   (llama.cpp with Qwen/Gemma templates); templates without it ignore it.
    # - reasoning_effort "none": the OpenAI-style knob, for servers that
    #   ignore the template switch (Splash thought until max_tokens).
    THINKING_OFF = {
      chat_template_kwargs: { enable_thinking: false },
      reasoning_effort: "none"
    }.freeze

    # @param base_url [String] the OpenAI API base, e.g. http://host:8081/v1
    # @param api_key_env [String, nil] the variable holding the host's key
    # @param timeout [Numeric] HTTP request timeout. Kept to the recap's own
    #   wait budget (not the chat's global request_timeout) so an abandoned
    #   summarize thread can't outlive the recap attempt by minutes.
    def initialize(model: DEFAULT_MODEL, base_url: nil, api_key_env: nil, timeout: DEFAULT_TIMEOUT_SECONDS, env: ENV)
      @model = model
      # A recap is best-effort: one short attempt, no retries. The idle job
      # tries again after the next activity, never on its own.
      @chat = LLM::OpenAIChat.new(base_url: base_url.to_s, host_name: "recap", api_key_env: api_key_env,
                                  stream: false, retries: false, timeout: timeout, env: env, purpose: "recap")
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

    # Summarize an already-built recap prompt: a string (one user message) or
    # a list of chat messages. Returns a Summary of the cleaned prose, or nil
    # when there is nothing to summarize. Any failure raises SummarizeError
    # (the caller isolates it).
    # @return [Summary, nil]
    def summarize(prompt)
      messages = prompt.is_a?(Array) ? prompt : [{ role: "user", content: prompt.to_s.strip }]
      return nil if messages.all? { |m| m[:content].to_s.strip.empty? }

      content, served = generate(messages)
      cleaned = content.to_s.strip
      cleaned.empty? ? nil : Summary.new(text: cleaned, model: served)
    rescue SummarizeError
      raise
    rescue StandardError => e
      raise SummarizeError, "recap summarization failed: #{e.class}: #{e.message}"
    end

    private

    # One plain /chat/completions request. Returns the cleaned assistant text
    # ("" when there is nothing after stripping) and the served model's name
    # (nil when the reply names none). Raises SummarizeError when
    # the reply has neither content nor reasoning_content.
    def generate(messages)
      response = @chat.chat(
        messages: messages, model: @model, tools: [],
        options: { max_tokens: MAX_TOKENS, **THINKING_OFF }
      )
      content = response.text
      reasoning = response.reasoning
      raise SummarizeError, "server returned no parseable assistant content" if content.empty? && reasoning.empty?

      cut_off = response.finish_reason == "length"
      # Reasoning cut off by max_tokens is the model's thinking, not a recap
      # (a server that ignores the thinking switch thinks until the limit).
      return ["", response.model] if content.empty? && cut_off

      # Prefer content, fall back to a finished reasoning_content (e.g.
      # Qwen3.6), and strip thinking tokens some models (Qwen, Gemma) leave
      # in the text.
      text = self.class.strip_thinking(content.empty? ? reasoning : content)
      # Cut off by max_tokens: keep the sentences that finished ("" if none).
      text = self.class.full_sentences(text) if cut_off
      [text, response.model]
    rescue LLM::ProtocolError => e
      raise SummarizeError, "server returned no parseable assistant content (#{e.message})"
    end

  end
end
