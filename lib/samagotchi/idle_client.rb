# frozen_string_literal: true

require "json"
require_relative "llm/adapters"
require_relative "log"

module Samagotchi
  # Standalone summarizer for the idle session-recap feature.
  #
  # Asks an OpenAI-compatible /chat/completions endpoint (the local llama.cpp,
  # or a recap host's) through its own adapter (LLM::Adapters.build, by the
  # target's api; OpenAIChat today): one plain request, no
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

    # What #summarize and #ask return: the text and the model that
    # answered (the server's name for it; nil when the reply names none).
    # +top_logprobs+: the first token's alternatives (LLM::TokenLogprob)
    # when #ask asked for logprobs and the server sent them, else [].
    # #to_s is the text.
    Summary = Data.define(:text, :model, :top_logprobs) do
      def initialize(top_logprobs: [].freeze, **) = super

      def to_s = text
    end

    DEFAULT_TIMEOUT_SECONDS = 30.0
    # Up to 10 sentences (recap.sentences) need ~350 tokens with thinking off.
    MAX_TOKENS = 512
    # The least max_tokens a side request gets when its model refused
    # thinking off and the adapter asks for a little thinking instead (an
    # always-thinking model on a Messages host): the thinking counts in the
    # limit, so 512 could all go to it and leave no answer.
    THINKING_MAX_TOKENS = 4096

    # @param base_url [String] the OpenAI API base, e.g. http://host:8081/v1
    # @param api_key_env [String, nil] the variable holding the host's key
    # @param timeout [Numeric] HTTP request timeout. Kept to the recap's own
    #   wait budget (not the chat's global request_timeout) so an abandoned
    #   summarize thread can't outlive the recap attempt by minutes.
    # @param purpose [String] what the requests are for, in the HTTP log
    #   lines and error messages ("recap", "broadcast")
    # @param api [Symbol] the wire to talk (LLM::Adapters; IdleTarget#api)
    # @param auth [Symbol, nil] the header the key goes in (IdleTarget#auth)
    # @param dialect [String, nil] a Messages host's dialect (IdleTarget#dialect)
    def initialize(model:, base_url: nil, api_key_env: nil, timeout: DEFAULT_TIMEOUT_SECONDS, env: ENV, purpose: "recap",
                   api: :openai, auth: nil, dialect: nil)
      @model = model
      # A recap is best-effort: one short attempt, no retries. The idle job
      # tries again after the next activity, never on its own. Only the
      # Messages adapter takes a dialect.
      @chat = LLM::Adapters.build(api: api, base_url: base_url.to_s, host_name: purpose, api_key_env: api_key_env,
                                  auth: auth, stream: false, retries: false, timeout: timeout, env: env, purpose: purpose,
                                  **(dialect ? { dialect: dialect } : {}))
    end

    # A client for +target+ (an IdleTarget: a recap's, ctx.ask_model's, a
    # broadcast's triage model), on its api's adapter.
    # @return [IdleClient]
    def self.for(target, **)
      new(model: target.model, base_url: target.base_url, api_key_env: target.api_key_env, api: target.api,
          auth: target.auth, dialect: target.dialect, **)
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
    # +session_id+: the session it is about, sent as the turns send it
    # (Session-Id, a dialect's affinity header), nil for none.
    def summarize(prompt, session_id: nil)
      messages = prompt.is_a?(Array) ? prompt : [{ role: "user", content: prompt.to_s.strip }]
      return nil if messages.all? { |m| m[:content].to_s.strip.empty? }

      response = generate(messages, session_id: session_id)
      cleaned = response.text.to_s.strip
      cleaned.empty? ? nil : Summary.new(text: cleaned, model: response.model)
    rescue SummarizeError
      raise
    rescue StandardError => e
      raise SummarizeError, "recap summarization failed: #{e.class}: #{e.message}"
    end

    # One side answer (a plugin's ctx.ask_model, a broadcast's triage):
    # +messages+ as they are, no tools, thinking off. An answer cut off by
    # +max_tokens+ is kept as it is, marked with "…". Cancelling
    # +cancel_controller+ aborts the request.
    # @param kind [String] what it is for, in the usage log line
    # @param options [Hash] more request body fields (logprobs: true,
    #   top_logprobs: 5)
    # @param session_id [String, nil] the session it is about (#summarize)
    # @return [Summary] the answer ("" when the model said nothing)
    # @raise [SummarizeError] any failure but a cancel; its #cause is an
    #   LLM::BadRequest when the host refused the request (+options+ it
    #   doesn't take, say)
    # @raise [LLM::RequestCancelled] +cancel_controller+ was cancelled
    def ask(messages, max_tokens: MAX_TOKENS, cancel_controller: nil, kind: "ask", options: {}, session_id: nil)
      response = generate(messages, max_tokens: max_tokens, cancel_controller: cancel_controller, whole_sentences: false,
                                    kind: kind, options: options, session_id: session_id)
      Summary.new(text: response.text.to_s.strip, model: response.model, top_logprobs: response.top_logprobs)
    rescue SummarizeError, LLM::RequestCancelled
      raise
    rescue StandardError => e
      raise SummarizeError, "the model request failed: #{e.class}: #{e.message}"
    end

    private

    # One plain /chat/completions request. Returns a Summary of the cleaned
    # assistant text ("" when there is nothing after stripping), the served
    # model's name (nil when the reply names none) and the first token's
    # logprobs. Raises SummarizeError when
    # the reply has neither content nor reasoning_content. Cut off by
    # +max_tokens+, the text keeps its finished sentences (+whole_sentences+)
    # or all of it, with "…".
    def generate(messages, max_tokens: MAX_TOKENS, cancel_controller: nil, whole_sentences: true, kind: "recap", options: {},
                 session_id: nil)
      response = begin
        request(messages, max_tokens, cancel_controller, options, session_id)
      rescue LLM::BadRequest => e
        raise unless e.reasoning_refused? && next_thinking_step

        Log.info(:recap, "thinking_refused", model: @model, step: @thinking_step, detail: e.detail)
        retry
      end
      log_usage(response, kind)
      content = response.text
      reasoning = response.reasoning
      raise SummarizeError, "server returned no parseable assistant content" if content.empty? && reasoning.empty?

      cut_off = response.finish_reason == "length"
      # Reasoning cut off by max_tokens is the model's thinking, not a recap
      # (a server that ignores the thinking switch thinks until the limit).
      return Summary.new(text: "", model: response.model, top_logprobs: response.top_logprobs) if content.empty? && cut_off

      # Prefer content, fall back to a finished reasoning_content (e.g.
      # Qwen3.6), and strip thinking tokens some models (Qwen, Gemma) leave
      # in the text.
      text = self.class.strip_thinking(content.empty? ? reasoning : content)
      # Cut off by max_tokens: keep the sentences that finished ("" if none).
      text = whole_sentences ? self.class.full_sentences(text) : "#{text}…" if cut_off && !text.empty?
      Summary.new(text: text, model: response.model, top_logprobs: response.top_logprobs)
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

    # After a host refused this step's thinking fields: the next step, kept
    # from now on (true), or false when none is left.
    # 1. The host won't turn thinking off (gpt-oss, an always-thinking
    #    model): the adapter's fields for that (none on the OpenAI API, low
    #    effort on Messages).
    # 2. Those refused too (a Messages model that takes no thinking fields
    #    at all): none.
    def next_thinking_step
      step = @thinking_step.to_i
      return false if step >= 2 || (step == 1 && @chat.thinking_off_refused_fields.empty?)

      @thinking_step = step + 1
      true
    end

    def request(messages, max_tokens, cancel_controller, options, session_id)
      fields = thinking_fields
      max_tokens = [max_tokens, THINKING_MAX_TOKENS].max if @thinking_step == 1 && !fields.empty?
      @chat.chat(messages: messages, model: @model, tools: [], cancel_controller: cancel_controller,
                 options: { max_tokens: max_tokens, **fields, **options }, session_id: session_id)
    end

    # A recap or side answer is short and tool-less: thinking off, whatever
    # the model's level (a reasoning model otherwise spends the budget
    # thinking and the recap stops mid-sentence). Once the host refused
    # that, the adapter's fields for a model that always thinks (with a
    # limit of at least THINKING_MAX_TOKENS when there are any), then none
    # (#next_thinking_step).
    def thinking_fields
      case @thinking_step.to_i
      when 0 then @chat.thinking_fields(:off)
      when 1 then @chat.thinking_off_refused_fields
      else {}
      end
    end
  end
end
