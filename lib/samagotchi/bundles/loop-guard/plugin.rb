# frozen_string_literal: true

# The loop-guard bundle (docs/plugins.md, The loop-guard bundle): a model
# that runs the same tool call again and again in one turn, getting the
# same result each time, is told to stop (a guardrail deny with advice),
# and after a few such denies the turn is stopped with a card that lists
# the repeated calls.
#
# A call is keyed by its tool and its arguments (whitespace collapsed), its
# result by a SHA1 of the output. Once a key has returned the same result
# deny_after times this turn, the next identical call is denied. A denied
# call records no result, so the deny sticks. The counts are per turn:
# before_turn resets them (a new user message can make an old call right
# again); steering merged mid-turn does not.
#
# It also watches the model's thinking while it streams (the
# :generation_progress hook): thinking that goes round in the same few
# sentences is cut (stop_generation) and the model asked again; if the
# retry loops too, the turn is stopped with a card. See ThinkingWatch.
#
# Settings (config.yml, bundles: loop-guard:):
#   deny_after: 2      same call + same result this many times -> deny the next
#   stop_after: 4      stop the turn at this many loop-guard denies
#   ignore_tools: [task_wait, task_get, delegate_result, list_sessions, list_reminders]
#   mode: deny         deny | notify (warn once per call, never deny or stop)
#   thinking:          the thinking watch (ThinkingWatch::DEFAULTS)
#     watch: true      false: the tool-call guard only
#     action: retry    retry (cut, ask again; then stop) | stop | notify
#     forget_after: 10 good steps (generations with no loop) in a row after a
#                      cut loop, and the next loop is cut again, not stopped;
#                      0: never forget, the turn's second loop stops it
require "digest"

# Sees thinking repeat itself, from the deltas of one generation.
#
# The thinking is cut into sentences (at . ! ? and newlines; a run-on over
# MAX_CARRY chars at its last space). Each sentence of min_words or more is
# normalized (lower case, letters and digits). Two sentences are alike when
# the mean of their word-set and word-bigram-set overlaps (Jaccard) is at
# least `similarity`: a reworded one ("Hmm, …", a synonym, a swapped
# clause) scores 0.4-0.9, two different ones rarely over 0.15. Two ways to
# see a loop:
# - a cycle: for each period p up to max_period, run[p] counts sentences in
#   a row alike the one p before. A cycle seen `repeats` times (run[p] >=
#   p * (repeats - 1)) is a loop once the looping stretch (run[p] + p
#   sentences) spans min_span_sentences and min_span_chars. Templated
#   sentences ("Now I need to open the file <path> and …") are alike too,
#   and an enumeration of them makes every period's run grow, so: a period
#   of 2 or more needs a cycle of distinct sentences (not all alike), and a
#   period of 1 (one sentence over and over) needs `similarity` +
#   SAME_MARGIN (0.9 by default: near-identical);
# - the same sentence max_same times in the generation, in any order;
# - a short run: short_run short sentences (under min_words) in a row, at
#   most short_distinct different ones among the last short_run ("I'll
#   write it. Go. OK. Writing. Go."). Normal thinking has short sentences
#   too ("Hmm.", "Fine."), but spread out, or in runs of different ones
#   (code lines); a sentence of min_words or more ends the run, one with no
#   letters or digits neither counts nor ends it. Lines inside a ``` code
#   block are not short sentences;
# - a low-diversity window: among the last window_sentences sentences of any
#   length, at most window_distinct different ones (exact, normalized). It
#   sees a cycle too long for the short run (7-8 short sentences), or one
#   where a longer sentence keeps ending the run ("Go. OK. I'll write the
#   spec file now. Go."). Real thinking holds 40+ different sentences in
#   any 48 (the lowest seen: 42); a loop holds under 10. Lines inside a ```
#   code block don't count.
# Nothing triggers before min_chars of thinking. O(new chars) per feed.
class ThinkingWatch
  DEFAULTS = { "watch" => true, "action" => "retry", "min_chars" => 2000, "repeats" => 3, "max_period" => 6,
               "similarity" => 0.5, "min_span_sentences" => 6, "min_span_chars" => 600, "max_same" => 8,
               "min_words" => 5, "short_run" => 24, "short_distinct" => 6, "window_sentences" => 48,
               "window_distinct" => 12, "forget_after" => 10 }.freeze
  ACTIONS = %w[retry stop notify].freeze
  MAX_CARRY = 400
  # One sentence again and again needs this much more alike than a cycle.
  SAME_MARGIN = 0.4
  MAX_DISTINCT = 5000
  SPLIT = /(?<=[.!?])\s+|\n+/

  # +span+: the sentences a loop that isn't a cycle (the short run, the
  # window) was seen in, +period+ the different ones among them; nil for a
  # cycle of +period+ sentences seen +times+ times.
  Loop = Struct.new(:period, :times, :sentences, :chars, :span, keyword_init: true) do
    # "one sentence ×8", "3 sentences ×3", "12 different sentences in 48".
    def describe
      return "one sentence ×#{times}" if period == 1
      return "#{period} sentences ×#{times}" unless span

      "#{period} different sentences in #{span}"
    end
  end
  Sentence = Struct.new(:text, :words, :bigrams, :key, :length, keyword_init: true)

  attr_reader :thinking_chars

  # @param settings [Hash] the thinking: settings (string keys), over DEFAULTS
  def self.settings(raw)
    raw = {} unless raw.is_a?(Hash)
    out = DEFAULTS.dup
    out["watch"] = !%w[false no off 0].include?(raw["watch"].to_s.downcase) if raw.key?("watch")
    out["action"] = raw["action"].to_s if ACTIONS.include?(raw["action"].to_s)
    %w[min_chars repeats max_period min_span_sentences min_span_chars max_same min_words short_run
       short_distinct window_sentences window_distinct].each do |key|
      number = Integer(raw[key].to_s, exception: false)
      out[key] = number if number&.positive?
    end
    forget = Integer(raw["forget_after"].to_s, exception: false)
    out["forget_after"] = forget if forget && forget >= 0
    similarity = Float(raw["similarity"].to_s, exception: false)
    out["similarity"] = similarity if similarity && similarity.positive? && similarity <= 1
    out["repeats"] = 2 if out["repeats"] < 2
    out
  end

  def initialize(settings = DEFAULTS)
    @min_chars = settings["min_chars"]
    @repeats = settings["repeats"]
    @max_period = settings["max_period"]
    @similarity = settings["similarity"]
    @min_span_sentences = settings["min_span_sentences"]
    @min_span_chars = settings["min_span_chars"]
    @max_same = settings["max_same"]
    @min_words = settings["min_words"]
    @short_run = settings["short_run"]
    @short_distinct = settings["short_distinct"]
    @window_sentences = settings["window_sentences"]
    @window_distinct = settings["window_distinct"]
    @same_similarity = [@similarity + SAME_MARGIN, 0.95].min
    @carry = +""
    @window = [] # the last max_period + 1 sentences
    @run = Array.new(@max_period + 1, 0)
    @run_chars = Array.new(@max_period + 1, 0) # chars of the run's sentences plus the first cycle's
    @counts = Hash.new(0)
    @short_count = 0  # short sentences in a row
    @short_window = [] # the last short_run of them, [key, text]
    @recent = [] # the last window_sentences sentences, [key, text]
    @recent_counts = Hash.new(0) # key => times in @recent
    @in_code = false
    @thinking_chars = 0
  end

  # @param delta [String] new thinking
  # @return [Loop, nil] the loop, once it is seen
  def feed(delta)
    delta = delta.to_s
    @thinking_chars += delta.length
    @carry << delta
    found = nil
    sentences.each do |text|
      loop_seen = add(text)
      found ||= loop_seen
    end
    found
  end

  private

  # The complete sentences in the carry; the unfinished tail stays.
  def sentences
    parts = @carry.split(SPLIT, -1)
    # An empty carry splits into no parts: nil.to_s is frozen, and the next
    # feed's << would raise (the watch went blind for that generation).
    @carry = +parts.pop.to_s
    if @carry.length > MAX_CARRY
      cut = @carry.rindex(" ", MAX_CARRY) || MAX_CARRY
      parts << @carry[0, cut]
      @carry = @carry[cut..].to_s.lstrip
    end
    parts
  end

  def add(text)
    if text.strip.start_with?("```")
      @in_code = !@in_code
      return nil
    end
    words = text.downcase.gsub(/[^[:alnum:]]+/, " ").split
    short = short_loop(text.strip, words) unless @in_code
    window = window_loop(text.strip, words) unless @in_code
    return (@thinking_chars >= @min_chars ? short || window : nil) if words.length < @min_words

    key = words.join(" ")
    sentence = Sentence.new(text: text.strip, words: words.map(&:hash).uniq,
                            bigrams: words.each_cons(2).map { |pair| pair.join(" ").hash }.uniq, key: key, length: text.length)
    same = count(key)
    cycle = cycle_loop(sentence)
    @window << sentence
    @window.shift if @window.length > @max_period + 1
    return nil if @thinking_chars < @min_chars

    cycle || (same >= @max_same ? Loop.new(period: 1, times: same, sentences: [sentence.text], chars: nil) : nil) || window
  end

  # The last window_sentences sentences (any length) hold at most
  # window_distinct different ones: a loop. Its sentences are the most
  # frequent first.
  def window_loop(text, words)
    return nil if words.empty?

    key = words.join(" ")
    @recent << [key, text]
    @recent_counts[key] += 1
    if @recent.length > @window_sentences
      old, = @recent.shift
      @recent_counts.delete(old) if (@recent_counts[old] -= 1).zero?
    end
    return nil if @recent.length < @window_sentences || @recent_counts.size > @window_distinct

    texts = @recent.to_h # key => its last text
    top = @recent_counts.sort_by { |_key, n| -n }.first(3).map { |key, _n| texts[key] }
    Loop.new(period: @recent_counts.size, times: @window_sentences / @recent_counts.size, sentences: top, chars: nil,
             span: @window_sentences)
  end

  def short_loop(text, words)
    return nil if words.empty?

    if words.length >= @min_words
      @short_count = 0
      @short_window.clear
      return nil
    end
    @short_count += 1
    @short_window << [words.join(" "), text]
    @short_window.shift if @short_window.length > @short_run
    return nil if @short_window.length < @short_run

    distinct = @short_window.uniq(&:first)
    return nil if distinct.length > @short_distinct

    Loop.new(period: distinct.length, times: @short_count / distinct.length, sentences: distinct.first(3).map(&:last), chars: nil,
             span: @short_window.length)
  end

  def count(key)
    return @counts[key] += 1 if @counts.key?(key) || @counts.size < MAX_DISTINCT

    0
  end

  def cycle_loop(sentence)
    found = nil
    (1..@max_period).each do |p|
      before = @window[-p]
      if before && similarity(sentence, before) >= (p == 1 ? @same_similarity : @similarity)
        # The run starts after one whole cycle: its chars count too.
        @run_chars[p] = @window.last(p).sum(&:length) if @run[p].zero?
        @run[p] += 1
        @run_chars[p] += sentence.length
      else
        @run[p] = 0
        @run_chars[p] = 0
        next
      end
      next if found || @run[p] < p * (@repeats - 1)
      next if @run[p] + p < @min_span_sentences || @run_chars[p] < @min_span_chars

      cycle = @window.last(p - 1) + [sentence]
      next if p > 1 && cycle.each_cons(2).all? { |a, b| similarity(a, b) >= @similarity }

      found = Loop.new(period: p, times: (@run[p] + p) / p, sentences: cycle.map(&:text), chars: @run_chars[p])
    end
    found
  end

  def similarity(a, b)
    return 1.0 if a.key == b.key

    (jaccard(a.words, b.words) + jaccard(a.bigrams, b.bigrams)) / 2
  end

  def jaccard(a, b)
    shared = (a & b).size
    all = a.size + b.size - shared
    all.zero? ? 0.0 : shared.to_f / all
  end
end

class Plugin
  DEFAULT_IGNORE = %w[task_wait task_get delegate_result list_sessions list_reminders].freeze
  # Built-in tools carry flat fields; plugin and unknown tools carry args:.
  # An edit's text is its old_text/new_text.
  KEY_FIELDS = %i[content path start_line end_line cwd env scope old_text new_text].freeze
  SHORT_CHARS = 60
  THOUGHT_CHARS = 80
  SOURCE = "bundle loop-guard"

  def initialize(settings = {})
    @deny_after = positive(settings["deny_after"]) || 2
    @stop_after = positive(settings["stop_after"]) || 4
    @ignore = settings.key?("ignore_tools") ? Array(settings["ignore_tools"]).map(&:to_s) : DEFAULT_IGNORE
    @mode = settings["mode"].to_s == "notify" ? :notify : :deny
    @thinking = ThinkingWatch.settings(settings["thinking"])
    reset
  end

  def register(chi)
    chi.on(:before_turn) { |_event| reset }
    chi.on(:before_tool_call) { |event, ctx| before(event, ctx) }
    chi.on(:after_tool_call) { |event| after(event) }
    return unless @thinking["watch"]

    chi.on(:before_generation) do |_event|
      good_step if @watch
      @watch = ThinkingWatch.new(@thinking)
      @watch_done = false
    end
    chi.on(:generation_progress) { |event, ctx| progress(event, ctx) }
  end

  private

  # A stretch of streamed thinking. The first loop in a turn is cut and the
  # model asked again (action retry); a second one, or action stop, stops
  # the turn with a card; action notify only warns, once per generation.
  def progress(event, ctx)
    return if @watch.nil? || @watch_done

    found = @watch.feed(event[:thinking])
    return unless found

    @watch_done = true
    what = "#{found.describe}, #{(@watch.thinking_chars / 1000.0).round}k chars, #{(event[:elapsed_ms].to_i / 1000.0).round} s"
    # The notices quote the loop's sentences on one line (a short cycle
    # whole), as the stop card does.
    quoted = "\"#{cut(found.sentences.first(3).join(" ").gsub(/\s+/, " "))}\", #{what}"
    case @thinking["action"]
    when "notify"
      ctx.notify("thinking repeats itself (#{quoted})", level: :warn)
    when "retry"
      @thinking_loops += 1
      return stop_thinking(ctx, found, what) if @thinking_loops > 1

      ctx.notify("thinking repeats itself (#{quoted}): cut", level: :warn) if ctx.stop_generation("its thinking kept repeating itself")
    else
      stop_thinking(ctx, found, what)
    end
  end

  # The generation before this one ended with no loop: a good step. After
  # forget_after of them in a row the turn's loops are forgotten, so a loop
  # long after the model recovered is cut and retried, not stopped.
  def good_step
    return @good_steps = 0 if @watch_done

    @good_steps += 1
    @thinking_loops = 0 if @good_steps == @thinking["forget_after"]
  end

  def stop_thinking(ctx, found, what)
    return unless ctx.stop_turn("the model's thinking kept repeating itself (#{what})")

    lines = found.sentences.first(3).map { |sentence| "- \"#{cut(sentence, THOUGHT_CHARS)}\"" }
    ctx.card(title: "loop-guard stopped the turn",
             body: "The model's thinking kept repeating itself:\n\n#{lines.join("\n")}\n\n" \
                   "Try: ask for a smaller step, or change the model's sampling (`sampling:` in config.yml).",
             level: :warn)
  end

  def reset
    @last_result = {}  # key => result hash
    @results = Hash.new(0) # [key, result hash] => times it ran with that result
    @previews = {}     # key => a short form of its last result
    @attempts = Hash.new(0) # key => calls this turn, denied ones too
    @warned = {}       # key => true once notified this turn
    @denials = 0
    @pending = nil
    @thinking_loops = 0
    @good_steps = 0
    @watch = nil
  end

  def before(event, ctx)
    call = event[:call]
    verdict = event[:guardrail]
    return unless call.is_a?(Hash) && verdict
    return if @ignore.include?(call[:name].to_s)

    key = key_for(call)
    @pending = { key: key, verdict: verdict }
    @attempts[key] += 1
    # Another voter denied it already: it won't run, and isn't ours to count.
    return if verdict.deny?

    last = @last_result[key]
    times = last ? @results[[key, last]] : 0
    return if times < @deny_after

    if @mode == :notify
      warn(ctx, key, "repeated #{times} times with the same result")
      return
    end

    verdict.deny!("repeated call", source: SOURCE, advice: advice(key, times))
    warn(ctx, key, "repeated, denied")
    @denials += 1
    stop(ctx) if @denials == @stop_after
  end

  # A call's result, paired with the before_tool_call that keyed it. A call
  # that was denied (by us or another voter) ran nothing: no result, or the
  # deny text would become the key's result and the next call would pass.
  def after(event)
    pending = @pending
    @pending = nil
    return unless pending && event[:tool].to_s == pending[:key].first
    return if pending[:verdict].deny?

    key = pending[:key]
    output = event[:output].to_s
    hash = Digest::SHA1.hexdigest(output)
    @last_result[key] = hash
    @results[[key, hash]] += 1
    @previews[key] = preview(output)
  end

  def stop(ctx)
    ctx.stop_turn("the model kept repeating the same calls")
    repeated = @attempts.select { |key, n| n > 1 && @last_result[key] && @results[[key, @last_result[key]]] >= @deny_after }
    lines = repeated.map do |key, n|
      "- `#{short_key(key)}`: #{n} times, the same result each time (#{@previews[key]})"
    end
    ctx.card(title: "loop-guard stopped the turn",
             body: "The model kept repeating these calls:\n\n#{lines.join("\n")}\n\n" \
                   "Tell it what to try instead, or where to look.",
             level: :warn)
  end

  def warn(ctx, key, what)
    return if @warned[key]

    @warned[key] = true
    ctx.notify("loop: #{short_key(key)} #{what}", level: :warn)
  end

  def advice(key, times)
    "You already ran this exact call #{times} times this turn and it returned the same result each time " \
      "(#{@previews[key]}). Don't repeat it. Try a different approach, or tell the user what you're stuck on."
  end

  def key_for(call)
    fields = call[:args].is_a?(Hash) ? call[:args] : call.slice(*KEY_FIELDS).compact
    [call[:name].to_s, normalize(fields)]
  end

  # Strings stripped and their whitespace collapsed; keys as strings.
  def normalize(value)
    case value
    when String then value.gsub(/\s+/, " ").strip
    when Hash then value.to_h { |k, v| [k.to_s, normalize(v)] }.sort.to_h
    when Array then value.map { |v| normalize(v) }
    else value
    end
  end

  def short_key(key)
    name, fields = key
    text = fields.is_a?(Hash) ? fields.values.map(&:to_s).reject(&:empty?).join(" ") : fields.to_s
    "#{name} #{cut(text)}".strip
  end

  # The output without its "[tool]" label, on one line.
  def preview(output)
    text = output.sub(/\A\[[\w.-]+\]\s*/, "").gsub(/\s+/, " ").strip
    text.empty? ? "no output" : cut(text)
  end

  def cut(text, max = SHORT_CHARS)
    text.length > max ? "#{text[0, max - 1]}…" : text
  end

  def positive(value)
    number = Integer(value.to_s, exception: false)
    number&.positive? ? number : nil
  end
end
