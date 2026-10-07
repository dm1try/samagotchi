# frozen_string_literal: true

require "json"
require_relative "llm/openai_chat"
require_relative "thinking"
require_relative "log"

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

    DEFAULT_TIMEOUT_SECONDS = 30.0
    # Up to 10 sentences (recap.sentences) need ~350 tokens with thinking off.
    MAX_TOKENS = 512

    # @param base_url [String] the OpenAI API base, e.g. http://host:8081/v1
    # @param api_key_env [String, nil] the variable holding the host's key
    # @param timeout [Numeric] HTTP request timeout. Kept to the recap's own
    #   wait budget (not the chat's global request_timeout) so an abandoned
    #   summarize thread can't outlive the recap attempt by minutes.
    def initialize(model:, base_url: nil, api_key_env: nil, timeout: DEFAULT_TIMEOUT_SECONDS, env: ENV)
      @model = model
      # A recap is best-effort: one short attempt, no retries. The idle job
      # tries again after the next activity, never on its own.
      @chat = LLM::OpenAIChat.new(base_url: base_url.to_s, host_name: "recap", api_key_env: api_key_env,
                                  stream: false, retries: false, timeout: timeout, env: env, purpose: "recap")
    end

    # A client for +target+ (an IdleTarget: a recap's, ctx.ask_model's, a
    # broadcast's triage model).
    # @return [IdleClient]
    def self.for(target, **)
      new(model: target.model, base_url: target.base_url, api_key_env: target.api_key_env, **)
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

    # One side answer (a plugin's ctx.ask_model): +messages+ as they are, no
    # tools, thinking off. An answer cut off by +max_tokens+ is kept as it
    # is, marked with "…". Cancelling +cancel_controller+ aborts the request.
    # @return [Summary] the answer ("" when the model said nothing)
    # @raise [SummarizeError] any failure but a cancel
    # @raise [LLM::RequestCancelled] +cancel_controller+ was cancelled
    def ask(messages, max_tokens: MAX_TOKENS, cancel_controller: nil)
      content, served = generate(messages, max_tokens: max_tokens, cancel_controller: cancel_controller, whole_sentences: false,
                                           kind: "ask")
      Summary.new(text: content.to_s.strip, model: served)
    rescue SummarizeError, LLM::RequestCancelled
      raise
    rescue StandardError => e
      raise SummarizeError, "the model request failed: #{e.class}: #{e.message}"
    end

    private

    # One plain /chat/completions request. Returns the cleaned assistant text
    # ("" when there is nothing after stripping) and the served model's name
    # (nil when the reply names none). Raises SummarizeError when
    # the reply has neither content nor reasoning_content. Cut off by
    # +max_tokens+, the text keeps its finished sentences (+whole_sentences+)
    # or all of it, with "…".
    def generate(messages, max_tokens: MAX_TOKENS, cancel_controller: nil, whole_sentences: true, kind: "recap")
      response = begin
        request(messages, max_tokens, cancel_controller)
      rescue LLM::BadRequest => e
        raise unless e.reasoning_refused? && !@thinking_refused

        # The host won't turn thinking off (gpt-oss): ask again without the
        # fields, and leave them out from now on.
        @thinking_refused = true
        Log.info(:recap, "thinking_refused", model: @model, detail: e.detail)
        request(messages, max_tokens, cancel_controller)
      end
      log_usage(response, kind)
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
      text = whole_sentences ? self.class.full_sentences(text) : "#{text}…" if cut_off && !text.empty?
      [text, response.model]
    rescue LLM::ProtocolError => e
      raise SummarizeError, "server returned no parseable assistant content (#{e.message})"
    end

    # The request's prompt-cache counts (a side request on the session's
    # host can evict the session's cached prompt there).
    def log_usage(response, kind)
      fields = response.usage&.cache_fields || {}
      return if fields.empty?

      Log.info(:recap, "request_usage", kind: kind, model: @model, prompt: fields[:prompt_tokens],
                                        cached: fields[:cached_tokens], cache_write: fields[:cache_write_tokens])
    end

    def request(messages, max_tokens, cancel_controller)
      @chat.chat(messages: messages, model: @model, tools: [], cancel_controller: cancel_controller,
                 options: { max_tokens: max_tokens, **thinking_fields })
    end

    # A recap or side answer is short and tool-less: thinking off, whatever
    # the model's level (a reasoning model otherwise spends the budget
    # thinking and the recap stops mid-sentence). None once the host refused them.
    def thinking_fields
      @thinking_refused ? {} : Thinking.chat_fields(:off)
    end
  end
end
