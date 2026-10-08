# frozen_string_literal: true

require_relative "config"
require_relative "context_usage"
require_relative "context_window"

module Samagotchi
  # One turn's context tracking for either loop: how full the window is
  # before each request (the server's last prompt count plus an estimate for
  # what the turn appended since, else a chars-per-token estimate), the
  # bucket that puts it in, and what comes of that:
  #
  # - the status line's value (#display), every request and again from the
  #   server's final counts after each generation;
  # - a :context_status stream event (#observe's return), on a bucket change
  #   or every context.status_cadence requests;
  # - the model's own short line (#take_guidance), once per rise into a
  #   bucket whose guidance asks for a change (the second threshold up).
  #
  # The context.* settings are read once, when the tracker is built (one per
  # run, so a changed setting counts from the next turn).
  #
  # The turn's LLM context strategy (LLMContextStrategy::Resolved) may set
  # a soft budget (llm_context.budget_tokens): the buckets then count
  # against it instead of the window (the smaller of the two).
  #
  # Under the forget layer the model's lines offer forget_outputs in
  # tiers, never "forget now" (the spike: told to free context, models
  # forget nearly everything), each with a "~N/M tokens" readout:
  # - the first bucket with guidance, below the top two: the readout alone
  #   (CLM: how-to at low pressure triggers wholesale deletion);
  # - the one under the top: finish the unit of work in flight, then tidy
  #   once;
  # - the top, or over the budget: compact settled outputs now, keep what
  #   will still be edited against, don't wipe.
  # When: at a turn's first request (the turn before it answered, its
  # outputs are settled), on a rise as ever, and again when the last line
  # was the readout alone (a mid-turn rise) or the context is over the
  # budget (every turn then). Mid-turn only the top tier offers; a lower
  # rise gets the readout alone (the layout check: pushed mid-task, models
  # forget at the base rate).
  class ContextStatus
    STATUS_PREFIX = "CONTEXT_STATUS"
    # The model's own line about its context (a tail system message, kind
    # LINE_KIND).
    LINE_PREFIX = "[CONTEXT: "
    LINE_KIND = "context"
    GUIDANCE_FROM_RANK = 2

    DEFAULT_CHARS_PER_TOKEN = 4.0
    DEFAULT_THRESHOLDS = [20, 40, 60, 80].freeze

    def self.enabled?
      Config.get("context.status") != false
    end

    # Healthy to critical; the top configured bucket gets the last, the
    # ones below it the ones before, and the first bucket (and the one
    # under it) is always healthy.
    GUIDANCE = [
      "context healthy — proceed normally",
      "context moderate — prefer targeted and range reads over full-file dumps",
      "context elevated — be concise, prefer range reads, avoid re-reading large files",
      "context critical — summarize aggressively, avoid large outputs, delegate broad work to subagents"
    ].freeze
    # The top level's words when the buckets count against a budget
    # (llm_context.budget_tokens) and no forget layer: nothing in the
    # model's hands shrinks the context, so no "summarize".
    BUDGET_CRITICAL = "context budget critical — avoid large outputs and re-reads, delegate broad work to subagents"

    # @param bucket [String] "under<N>" or "<N>plus"
    # @param thresholds [Array<Integer>] the configured ones, sorted
    # @param budget [Boolean] the buckets count against a budget
    def self.guidance(bucket, thresholds = DEFAULT_THRESHOLDS, budget: false)
      rank = bucket_rank(bucket, thresholds)
      level = rank < GUIDANCE_FROM_RANK ? 0 : GUIDANCE.size - 1 - (thresholds.size - rank)
      level = level.clamp(0, GUIDANCE.size - 1)
      return BUDGET_CRITICAL if budget && level == GUIDANCE.size - 1

      GUIDANCE[level]
    end

    # 0 for the bucket under the first threshold, then one per threshold.
    def self.bucket_rank(bucket, thresholds)
      return 0 if bucket.nil? || bucket.to_s.start_with?("under")

      (thresholds.index(bucket.to_s.delete_suffix("plus").to_i) || -1) + 1
    end

    # The bucket of the last status line +conversation+ holds: the model's
    # own line, or a legacy session's injected telemetry.
    def self.last_bucket(conversation)
      content = last_line(conversation)
      match = content&.match(/\bbucket=([a-z0-9_]+)/)
      match && match[1]
    end

    # The text of the last status line +conversation+ holds, nil for none.
    def self.last_line(conversation)
      message = conversation.reverse.find do |entry|
        content = entry[:content].to_s
        entry[:role] == "system" && content.start_with?(STATUS_PREFIX, LINE_PREFIX)
      end
      message && message[:content].to_s
    end

    # What a forget-layer line names when it offers the tool.
    OFFER_TOOL = "forget_outputs"
    # The forget layer's tiers' words (#forget_line).
    TIDY = "Finish the unit of work in flight, then tidy once with #{OFFER_TOOL}: settled outputs, with a note " \
           "that carries what they established."
    COMPACT = "Compact settled outputs now with #{OFFER_TOOL}: keep what you'll still edit against; don't wipe."

    # @param conversation [Array<Hash>] the turn's conversation so far (its
    #   last status line's bucket is where rises count from)
    # @param llm_context [LLMContextStrategy::Resolved, nil] the turn's
    #   strategy (its budget)
    def initialize(conversation: [], llm_context: nil)
      @budget = llm_context&.budget_tokens
      @forget = llm_context&.forget? || false
      @offered = self.class.last_line(conversation).to_s.include?(OFFER_TOOL)
      @enabled = self.class.enabled?
      chars_per_token = Config.get("context.chars_per_token").to_f
      @chars_per_token = chars_per_token.positive? ? chars_per_token : DEFAULT_CHARS_PER_TOKEN
      parsed = Config.get("context.status_thresholds").to_s.split(",").map { |value| value.strip.to_i }
                     .select { |value| value.between?(1, 99) }.uniq.sort
      @thresholds = parsed.empty? ? DEFAULT_THRESHOLDS : parsed
      @cadence = [Config.get("context.status_cadence").to_i, 0].max
      @last_bucket = self.class.last_bucket(conversation)
      @server_usage = nil
      @counted = nil
      @edited = false
      @display = nil
      @guidance = nil
    end

    # @return [Hash, nil] the status line's value ({est_pct:, bucket:});
    #   nil with context.status off or before the first request
    attr_reader :display

    def enabled? = @enabled

    # The status line's value is in the top configured bucket (the apply
    # rule's payoff applies staged edits there at once).
    def top_bucket?
      !@display.nil? && bucket_rank(@display[:bucket]) == @thresholds.size
    end

    # Before a request: estimate the usage of a prompt of +prompt_chars+
    # against +window+ (this request's ContextWindow::Resolved) and update
    # the status line's value. A rise into a bucket that asks the model for
    # a change leaves a line for #take_guidance.
    # +image_tokens+: the images' estimate (their base64 is not in the chars).
    #
    # @return [Hash, nil] the :context_status event's fields (without
    #   :type/:iteration) when the emit gate fires, else nil
    def observe(prompt_chars, iteration_index:, window:, image_tokens: 0)
      return nil unless @enabled

      usage = estimate(prompt_chars, server_usage: @server_usage, window: window, image_tokens: image_tokens, counted: @counted)
      bucket = bucket_for(usage[:estimated_pct])
      # The status line's value, every iteration; the gate below decides
      # only the event and the model's guidance line.
      @display = { est_pct: usage[:estimated_pct], bucket: bucket }
      emit = emit?(bucket: bucket, iteration_index: iteration_index)
      previous_bucket = @last_bucket
      @last_bucket = bucket
      line = if @forget
               forget_line(usage, bucket, previous_bucket, iteration_index)
             elsif guidance_due?(previous_bucket, bucket)
               guidance_message(usage: usage, bucket: bucket)
             end
      @guidance = line if line
      return nil unless emit

      { status: status_message(usage: usage, bucket: bucket), usage: usage, bucket: bucket, source: usage[:source] }
    end

    # An LLM context edit was applied (LLMContextApply): the prompt is
    # shorter than the one the server's count was for. Until the next
    # count the estimate takes what the prompt lost off that count too,
    # instead of holding it (a shorter prompt counts as trimmed otherwise).
    def edited!
      @edited = true
    end

    # @return [Hash, nil] the model's line from the last #observe (once)
    def take_guidance
      line = @guidance
      @guidance = nil
      line
    end

    # A stream payload's counts, kept for the next estimate.
    # @return [Hash, nil] the payload's normalized counts, when it has any
    def capture(payload)
      normalized = ContextUsage.normalize(payload)
      @server_usage = normalized if normalized
      normalized
    end

    # After a generation: +usage+ is its own server counts ({prompt_tokens:,
    # total_tokens:, context_window_tokens:}; nil: none), for
    # +prompt_chars+/+image_tokens+ as sent. The next estimate adds only
    # what the turn appended since (answer, tool results), and the status
    # line's value counts the answer. Without counts the pre-generation
    # estimate stays.
    def generation_done(usage, prompt_chars:, image_tokens:, window:)
      return unless usage

      @counted = { chars: prompt_chars, image_tokens: image_tokens }
      @edited = false
      value = display_for(used_tokens: usage[:total_tokens], window_tokens: usage[:context_window_tokens] || window&.tokens)
      @display = value if value
    end

    # The status line's value ({est_pct:, bucket:}) for +used_tokens+ of
    # +window_tokens+; nil without both, or with context.status off.
    def display_for(used_tokens:, window_tokens:)
      return nil unless @enabled
      return nil unless ContextWindow.positive_integer?(used_tokens) && ContextWindow.positive_integer?(window_tokens)

      pct = (used_tokens.to_f / counted_against(window_tokens)) * 100.0
      { est_pct: pct, bucket: bucket_for(pct) }
    end

    # `window` is this request's ContextWindow::Resolved. A window the
    # stream payload reports itself still wins.
    # +counted+: the prompt the server's prompt_tokens counted ({chars:,
    # image_tokens:}); what the prompt has on top of it (the answer, tool
    # results since) is added as an estimate, so the value doesn't read low
    # during a long tool loop. A prompt shorter than that one (trimmed) or
    # none known: the server's count alone.
    def estimate(prompt_chars, window:, server_usage: nil, image_tokens: 0, counted: nil)
      window_source = window.source
      window_source = :server if server_usage && server_usage[:context_window_tokens]

      if server_usage && server_usage[:prompt_tokens]
        window_tokens = counted_against(server_usage[:context_window_tokens] || window.tokens)
        used_tokens = [server_usage[:prompt_tokens] + appended_tokens(prompt_chars, image_tokens, counted), 0].max
        source = "server"
      else
        window_tokens = counted_against(window.tokens)
        used_tokens = (prompt_chars / @chars_per_token).ceil + image_tokens
        source = "estimate"
      end

      {
        window_tokens: window_tokens,
        window_source: window_source,
        estimated_used_tokens: used_tokens,
        estimated_remaining_tokens: [window_tokens - used_tokens, 0].max,
        estimated_pct: (used_tokens.to_f / window_tokens) * 100.0,
        source: source
      }
    end

    private

    # What the buckets count against: the window, or the budget when one is
    # set and smaller.
    def counted_against(window_tokens)
      @budget ? [@budget, window_tokens].min : window_tokens
    end

    # The estimate for what the prompt added since the +counted+ one;
    # after an edit (#edited!) what it lost too, as a negative.
    def appended_tokens(prompt_chars, image_tokens, counted)
      return 0 unless counted

      chars = prompt_chars - counted[:chars]
      return -(-chars / @chars_per_token).ceil if @edited && chars.negative?
      return 0 unless chars.positive?

      (chars / @chars_per_token).ceil + [image_tokens - counted[:image_tokens].to_i, 0].max
    end

    def bucket_for(estimated_pct)
      bucket = "under#{@thresholds.first}"
      @thresholds.each do |threshold|
        bucket = "#{threshold}plus" if estimated_pct >= threshold
      end
      bucket
    end

    def bucket_rank(bucket) = self.class.bucket_rank(bucket, @thresholds)

    # A rise (never a fall or a cadence tick) into a bucket whose guidance
    # asks for a change. With no previous bucket (a first turn, a resumed
    # session with no line yet), the first bucket counts as a rise from 0.
    def guidance_due?(previous, bucket)
      rank = bucket_rank(bucket)
      rank >= GUIDANCE_FROM_RANK && rank > bucket_rank(previous)
    end

    def emit?(bucket:, iteration_index:)
      bucket_changed = bucket != if @last_bucket.nil?
                                   "under#{@thresholds.first}"
                                 else
                                   @last_bucket
                                 end
      cadence_due = @cadence.positive? && ((iteration_index + 1) % @cadence).zero?
      bucket_changed || cadence_due
    end

    # The forget layer's line for this request, or nil (the tiers and when
    # they come: the class comment).
    def forget_line(usage, bucket, previous, iteration_index)
      over = over_budget?(usage)
      tier = over ? :compact : tier_for(bucket)
      return nil unless tier

      rise = guidance_due?(previous, bucket)
      if iteration_index.zero?
        return nil unless rise || over || (tier != :info && !@offered)
      else
        return nil unless rise

        tier = :info unless tier == :compact
      end
      @offered = tier != :info
      readout = "~#{k(usage[:estimated_used_tokens])}/#{k(usage[:window_tokens])} tokens in use"
      readout += ", over the budget" if over
      words = { info: nil, tidy: TIDY, compact: COMPACT }.fetch(tier)
      { role: "system", kind: LINE_KIND, content: "#{LINE_PREFIX}#{readout} (bucket=#{bucket}).#{" #{words}" if words}]" }
    end

    # :info, :tidy or :compact for a bucket with guidance (the top one
    # compacts, the one under it tidies, lower ones inform); nil below.
    def tier_for(bucket)
      rank = bucket_rank(bucket)
      return nil if rank < GUIDANCE_FROM_RANK
      return :compact if rank == @thresholds.size

      rank == @thresholds.size - 1 ? :tidy : :info
    end

    def over_budget?(usage) = !@budget.nil? && usage[:estimated_used_tokens] >= @budget

    def k(tokens) = tokens >= 1000 ? "#{(tokens / 1000.0).round}k" : tokens.to_s

    # The buckets count against the budget (set, and not over the window).
    def budget_counted?(usage) = !@budget.nil? && usage[:window_tokens] == @budget

    def guidance_message(usage:, bucket:)
      how = usage[:source].to_s == "server" ? "as the server reports" : "estimated"
      budget = budget_counted?(usage)
      of = budget ? "the context budget (#{k(@budget)} tokens)" : "the context window"
      { role: "system", kind: LINE_KIND,
        content: "#{LINE_PREFIX}about #{usage[:estimated_pct].to_f.round}% of #{of} is in use " \
                 "(#{how}; bucket=#{bucket}). #{self.class.guidance(bucket, @thresholds, budget: budget)}]" }
    end

    def status_message(usage:, bucket:)
      format(
        "%<prefix>s window_tokens=%<window>d window_src=%<window_src>s est_used_tokens=%<used>d est_remaining_tokens=%<remaining>d est_pct=%<pct>.1f bucket=%<bucket>s thresholds=%<thresholds>s src=%<src>s guidance=%<guidance>s",
        prefix: STATUS_PREFIX,
        window: usage[:window_tokens],
        window_src: usage[:window_source] || "default",
        used: usage[:estimated_used_tokens],
        remaining: usage[:estimated_remaining_tokens],
        pct: usage[:estimated_pct],
        bucket: bucket,
        thresholds: @thresholds.join(","),
        src: usage[:source],
        guidance: self.class.guidance(bucket, @thresholds, budget: budget_counted?(usage))
      )
    end
  end
end
