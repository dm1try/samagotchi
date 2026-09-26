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
# Settings (config.yml, bundles: loop-guard:):
#   deny_after: 2      same call + same result this many times -> deny the next
#   stop_after: 4      stop the turn at this many loop-guard denies
#   ignore_tools: [task_wait, task_get, delegate_result, list_sessions, list_reminders]
#   mode: deny         deny | notify (warn once per call, never deny or stop)
require "digest"

class Plugin
  DEFAULT_IGNORE = %w[task_wait task_get delegate_result list_sessions list_reminders].freeze
  # Built-in tools carry flat fields; plugin and unknown tools carry args:.
  KEY_FIELDS = %i[content path start_line end_line cwd env scope].freeze
  SHORT_CHARS = 60
  SOURCE = "bundle loop-guard"

  def initialize(settings = {})
    settings = {} unless settings.is_a?(Hash)
    @deny_after = positive(settings["deny_after"]) || 2
    @stop_after = positive(settings["stop_after"]) || 4
    @ignore = settings.key?("ignore_tools") ? Array(settings["ignore_tools"]).map(&:to_s) : DEFAULT_IGNORE
    @mode = settings["mode"].to_s == "notify" ? :notify : :deny
    reset
  end

  def register(chi)
    chi.on(:before_turn) { |_event| reset }
    chi.on(:before_tool_call) { |event, ctx| before(event, ctx) }
    chi.on(:after_tool_call) { |event| after(event) }
  end

  private

  def reset
    @last_result = {}  # key => result hash
    @results = Hash.new(0) # [key, result hash] => times it ran with that result
    @previews = {}     # key => a short form of its last result
    @attempts = Hash.new(0) # key => calls this turn, denied ones too
    @warned = {}       # key => true once notified this turn
    @denials = 0
    @pending = nil
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
    stop(event, ctx) if @denials == @stop_after
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

  def stop(event, ctx)
    event[:stop_turn]&.call("the model kept repeating the same calls")
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

  def cut(text)
    text.length > SHORT_CHARS ? "#{text[0, SHORT_CHARS - 1]}…" : text
  end

  def positive(value)
    number = Integer(value.to_s, exception: false)
    number&.positive? ? number : nil
  end
end
