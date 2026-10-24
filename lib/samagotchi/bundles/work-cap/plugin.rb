# frozen_string_literal: true

# The work-cap bundle (docs/plugins.md, The work-cap bundle): a per-session
# cap on the work a session does across its turns (ctx.usage: tool calls,
# active minutes), the session-wide bound the per-turn step limit and
# check-in don't give. Before each generation it compares the work with the
# caps: at warn_at of a cap the user (only) gets one notice, at a cap the
# turn pauses on a question, Continue (the cap goes up by a step) or Stop
# (the turn stops, with a card). With no one to ask it stops. The question
# names the session's totals, so a parent agent answering it decides on the
# whole picture. The model never sees any of it: no tool, no steer, no
# prompt text. cost-cap (the $ cap) is its sibling; the wordings follow it.
#
# Settings (config.yml, bundles: work-cap:), from ctx.settings, never at
# load: the caps are resolved once per session and settings (see State
# below), again when ctx.settings changes, so a config change reaches a
# running session (the state file still wins per meter); warn_at and
# ignore_tools are read at each check.
#   tool_calls: 400   this session's own tool-call cap (session_settings:,
#                     chi --set work-cap.tool_calls=400); 0/off: none
#   minutes: 60       this session's own cap on active minutes, same rules
#   child: {tool_calls: 500, minutes: 90}   delegates (ctx.delegate?) with
#                     no own value
#   default: {}       every other session (and a delegate without child:)
#   warn_at: 0.8      the share of a cap that warns; 0/off: no warning
#   ignore_tools: [task_wait, task_get, delegate, delegate_result]
#                     tools whose calls and time aren't counted (waiting:
#                     delegate blocks on its child by default)
# Each meter resolves on its own: its own value, else child:'s for a
# delegate, else default:'s. An empty key (YAML nil) is unset and falls
# through; off, false and 0 are an explicit "no cap". A value that doesn't
# read (tool_calls: many) warns the user once and the next one is used,
# never a silent "no cap".
#
# What counts: ctx.usage's tool calls and active time (generations plus
# finished tool calls, never a question's wait), less ignore_tools'.
#
# State: <data_dir>/sessions/<session id>.json, {"tool_calls": {"cap": 800,
# "step": 400}, "minutes": {"cap": null}}, written by /workcap and by
# Continue; a meter's "cap": null is off for the session, over the config;
# a meter missing from the file comes from the settings. Resolved once per
# session id and settings (ctx.delegate? parses the session file) and kept
# until /workcap or Continue writes a new file, or the settings change.
require "json"
require "fileutils"

class Plugin
  USAGE = "usage: /workcap [N | Nm | Nh | off] (N tool calls, Nm or Nh active time; /workcap alone shows the totals)"
  OPTIONS = %w[Continue Stop].freeze
  # For a parent agent's answer (guardrails.parent_answers): Continue
  # spends more, Stop denies; under hard a parent may only Stop.
  EFFECTS = { "Continue" => :spend, "Stop" => :deny }.freeze
  WARN_AT = 0.8
  METERS = %w[tool_calls minutes].freeze
  DEFAULT_IGNORE = %w[task_wait task_get delegate delegate_result].freeze
  # A cap as text: 3, 2.5, .5, 1e1, -1 (a negative is none).
  NUMBER = /\A-?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?\z/i
  # Minutes as text: a NUMBER, or one with m/min (minutes) or h (hours).
  DURATION = /\A(?<number>.+?)\s*(?<unit>m|min|mins|minutes|h|hours?)?\z/i

  def initialize(_settings)
    @mutex = Mutex.new
    @resolved = nil        # {session:, settings:, meters: {meter => {cap:, step:, key:}}, unreadable: {name => value}}
    @warned = {}           # meter => [session id, cap] the share warning was given for
    @unread_warned = nil   # the session id the "isn't a number" notice was given for
    @corrupt_warned = nil  # the session id the "state file doesn't read" notice was given for
  end

  def register(chi)
    chi.on(:before_generation) { |_event, ctx| check(ctx) }
    chi.command("/workcap", "see or set this session's work cap: /workcap, /workcap 400, /workcap 90m, /workcap off",
                anytime: true) do |args, ctx|
      command(args, ctx)
    end
  end

  # A cap (a positive Float) or nil (none, 0, off, false, or a value that
  # isn't a number: .readable? tells them apart). Minutes take a unit:
  # 90m, 1.5h.
  def self.amount(value, meter)
    number = number(value, meter)
    number&.positive? ? number : nil
  end

  # +value+ as a finite Float, else nil. "5." gets its 0 first
  # (.float_text: Ruby 3.3's Float wants one).
  def self.number(value, meter)
    number = case value
             when Numeric then value.to_f
             when String then text_number(value.strip, meter)
             end
    number if number&.finite?
  end

  def self.text_number(text, meter)
    return Float(float_text(text)) if text.match?(NUMBER)
    return nil unless meter == "minutes" && (match = DURATION.match(text)) && match[:unit]
    return nil unless match[:number].match?(NUMBER)

    Float(float_text(match[:number])) * (match[:unit].downcase.start_with?("h") ? 60 : 1)
  end

  # A NUMBER as Float reads it on every Ruby: a bare point ("5.", "5.e1")
  # gets a 0 after it.
  def self.float_text(text) = text.sub(/\.(?=e|\z)/i, ".0")

  # Whether +value+ reads as a cap or as none: a number (text too), off,
  # false or nil (nil is unset, not none: #first_readable skips it); not
  # "many", true or a list.
  def self.readable?(value, meter)
    case value
    when false, nil then true
    when Numeric then value.finite?
    when String then value.strip.casecmp?("off") || !number(value, meter).nil?
    else false
    end
  end

  # 400, 2.5: a whole number without its ".0".
  def self.count(value)
    rounded = value.round(1)
    rounded == rounded.to_i ? rounded.to_i.to_s : rounded.to_s
  end

  private

  def check(ctx)
    resolved = resolve(ctx)
    unreadable(ctx, resolved)
    corrupt(ctx, resolved)
    capped = resolved[:meters].select { |_meter, meter_cap| meter_cap[:cap] }
    return if capped.empty?

    usage = ctx.usage
    used = used(ctx, usage)
    reached = capped.select { |meter, meter_cap| used[meter] >= meter_cap[:cap] }
    return at_cap(ctx, resolved, reached, usage, used) unless reached.empty?

    share = warn_share(ctx)
    return unless share

    capped.each do |meter, meter_cap|
      cap = meter_cap[:cap]
      next unless used[meter] >= share * cap && first_warning?(meter, [resolved[:session], cap])

      ctx.notify("#{count(used[meter])} of #{count(cap)} #{unit(meter)} (#{(used[meter] / cap * 100).floor}%)",
                 level: :warn)
    end
  end

  # The counted work per meter: tool calls and active minutes, less the
  # ignored tools' share.
  def used(ctx, usage)
    ignored = ignore_tools(ctx)
    calls = usage.tool_calls - ignored.sum { |tool| usage.tool_calls_by_tool.fetch(tool, 0) }
    active_ms = usage.active_ms - ignored.sum { |tool| usage.tool_ms_by_tool.fetch(tool, 0) }
    { "tool_calls" => [calls, 0].max.to_f, "minutes" => [active_ms, 0].max / 60_000.0 }
  end

  # Once per session: the settings whose cap didn't read, and what is used.
  def unreadable(ctx, resolved)
    bad = resolved[:unreadable]
    return if bad.empty? || !first_time?(:@unread_warned, resolved[:session])

    named = bad.map { |key, value| "#{key}: #{value.inspect}" }.join(" and ")
    ctx.notify("work-cap: #{named} #{bad.size == 1 ? "isn't" : "aren't"} a number or off; #{using(resolved)}",
               level: :warn)
  end

  # Once per session: a state file that is there but doesn't read (not
  # JSON, or not a mapping) holds no /workcap caps, so the settings' are
  # used; said rather than a /workcap cap silently gone.
  def corrupt(ctx, resolved)
    path = resolved[:corrupt]
    return unless path && first_time?(:@corrupt_warned, resolved[:session])

    ctx.notify("work-cap: #{path} doesn't read, its /workcap caps are ignored; #{using(resolved)}", level: :warn)
  end

  # "using tool_calls: (400), minutes: (60)", or "no cap".
  def using(resolved)
    used = resolved[:meters].values.filter_map do |meter_cap|
      "#{meter_cap[:key]}: (#{count(meter_cap[:cap])})" if meter_cap[:cap]
    end
    used.empty? ? "no cap" : "using #{used.join(", ")}"
  end

  def at_cap(ctx, resolved, reached, usage, used)
    raised = reached.to_h do |meter, meter_cap|
      [meter, raised_cap(meter_cap[:cap], meter_cap[:step] || meter_cap[:cap], used[meter])]
    end
    answer = ctx.ask_user(question: "Work cap reached: #{reached_text(reached, used)} (#{totals(ctx, usage, used, reached.keys)}). " \
                                    "Continue raises #{raised_text(raised)}.",
                          header: "Work cap", options: OPTIONS, effects: EFFECTS)
    if continue?(answer)
      raised.each do |meter, cap|
        save_meter(ctx, resolved[:session], meter, "cap" => cap, "step" => reached[meter][:step] || reached[meter][:cap])
      end
      ctx.notify("#{raised.size == 1 ? "cap" : "caps"} raised to " \
                 "#{raised.map { |meter, cap| "#{count(cap)} #{unit(meter)}" }.join(" and ")}")
    else
      stop(ctx, reached, usage, used)
    end
  end

  # "412 tool calls of 400", and "61 active minutes of 60" for the other.
  def reached_text(reached, used)
    reached.map { |meter, meter_cap| "#{count(used[meter])} #{unit(meter)} of #{count(meter_cap[:cap])}" }.join(", ")
  end

  # "it to 800", or "them to 800 tool calls and 120 active minutes".
  def raised_text(raised)
    return "it to #{count(raised.values.first)}" if raised.size == 1

    "them to #{raised.map { |meter, cap| "#{count(cap)} #{unit(meter)}" }.join(" and ")}"
  end

  # The session's totals a reader decides on, the reached meters left out
  # (already named): turns, tool calls, active minutes and the spend.
  def totals(ctx, usage, used, skip = [])
    parts = ["#{usage.turns} #{usage.turns == 1 ? "turn" : "turns"}"]
    parts << "#{count(used["tool_calls"])} tool calls" unless skip.include?("tool_calls")
    parts << "#{active_text(used["minutes"])} active" unless skip.include?("minutes")
    cost = ctx.cost
    parts << format("$%.2f", cost.total) if cost.known? && cost.total.positive?
    parts.join(", ")
  end

  # "47 min", or "<1 min" before a whole minute of work.
  def active_text(minutes) = minutes < 1 ? "<1 min" : "#{count(minutes.floor)} min"

  # Another step on the cap, as many steps as it takes to pass the work
  # (a turn that overshot by more than a step asks once, not each step):
  # Continue always leaves the cap past the work now.
  def raised_cap(cap, step, used)
    raised = cap + step
    raised += step while raised <= used
    raised.round(6)
  end

  def continue?(answer)
    return false unless answer

    Array(answer[:selected]).first == "Continue" || Array(answer[:selected_indices]).first&.zero?
  end

  def stop(ctx, reached, usage, used)
    return unless ctx.stop_turn("work cap reached (#{reached_text(reached, used)})")

    ctx.card(title: "work-cap stopped the turn",
             body: "Used #{reached_text(reached, used)} (#{totals(ctx, usage, used, reached.keys)}).\n\n" \
                   "`/workcap N` raises the tool-call cap, `/workcap Nm` the active minutes, `/workcap off` removes both.",
             level: :warn)
  end

  def command(args, ctx)
    arg = args.to_s.strip.downcase
    return show(ctx) if arg.empty?

    session = ctx.session_id
    return "work-cap: no session yet" unless session

    if %w[off 0].include?(arg)
      METERS.each { |meter| save_meter(ctx, session, meter, "cap" => nil) }
      return "work-cap: no cap for this session"
    end
    meter = arg.match?(NUMBER) ? "tool_calls" : "minutes"
    value = self.class.amount(arg, meter)
    return USAGE unless value

    save_meter(ctx, session, meter, "cap" => value, "step" => value)
    "work-cap: #{unit(meter)} cap set to #{count(value)} (#{count(used(ctx, ctx.usage)[meter])} so far)"
  rescue StandardError => e
    ctx.log.warn(:workcap_command_failed, error: "#{e.class}: #{e.message}")
    "work-cap: #{e.message}"
  end

  def show(ctx)
    usage = ctx.usage
    used = used(ctx, usage)
    meters = resolve(ctx)[:meters]
    return "work-cap: no cap (#{totals(ctx, usage, used)})" if meters.values.none? { |meter_cap| meter_cap[:cap] }

    capped = meters.select { |_meter, meter_cap| meter_cap[:cap] }
    caps = capped.map { |meter, meter_cap| "#{count(used[meter])} of #{count(meter_cap[:cap])} #{unit(meter)}" }
    "work-cap: #{caps.join(", ")} (#{totals(ctx, usage, used, capped.keys)})"
  end

  def unit(meter) = meter == "tool_calls" ? "tool calls" : "active minutes"

  # The session's caps now: per meter the state file's, else the session's
  # own value (--set), else child:'s for a delegate, else default:'s.
  # Cached per session id and settings (a config change resolves again).
  def resolve(ctx)
    session = ctx.session_id
    settings = ctx.settings
    cached = @mutex.synchronize { @resolved }
    return cached if cached && cached[:session] == session && cached[:settings] == settings

    saved, corrupt = state(ctx, session)
    configured = configured(ctx)
    meters = METERS.to_h { |meter| [meter, saved[meter] || configured[:meters][meter]] }
    resolved = { session: session, settings: settings, meters: meters, unreadable: configured[:unreadable],
                 corrupt: corrupt }
    @mutex.synchronize { @resolved = resolved }
  end

  # The state file's meters ({meter => {cap:, step:}}), {} without one,
  # and the file's path when it is there but doesn't read (logged; the
  # user is told by #corrupt), else nil.
  def state(ctx, session)
    return [{}, nil] unless session

    path = state_path(ctx, session)
    saved = JSON.parse(File.read(path))
    raise JSON::ParserError, "not a JSON object" unless saved.is_a?(Hash)

    meters = METERS.each_with_object({}) do |meter, found|
      entry = saved[meter]
      next unless entry.is_a?(Hash) && entry.key?("cap")

      cap = self.class.amount(entry["cap"], meter)
      found[meter] = { cap: cap, step: self.class.amount(entry["step"], meter) || cap, key: "/workcap" }
    end
    [meters, nil]
  rescue Errno::ENOENT
    [{}, nil]
  rescue JSON::ParserError => e
    ctx.log.warn(:workcap_state_unreadable, path: path, error: e.message.to_s[0, 200])
    [{}, path]
  end

  # Per meter the first of its own value, child:'s (a delegate's) and
  # default:'s that is set (an empty key, nil, isn't) and reads
  # (.readable?); the ones set that don't read (and a child:/default: that
  # isn't a mapping) are kept for the notice (#unreadable).
  def configured(ctx)
    settings = ctx.settings
    unreadable = {}
    groups = %w[child default].select { |group| settings.key?(group) }
    groups.delete("child") if groups.include?("child") && !ctx.delegate?
    groups = groups.select do |group|
      next true if settings[group].is_a?(Hash)

      unreadable[group] = settings[group] unless settings[group].nil?
      false
    end
    meters = METERS.to_h do |meter|
      sources = [[meter, settings, meter]] + groups.map { |group| ["#{group}.#{meter}", settings[group], meter] }
      [meter, first_readable(sources, unreadable)]
    end
    { meters: meters, unreadable: unreadable }
  end

  def first_readable(sources, unreadable)
    sources.each do |name, values, meter|
      next unless values.key?(meter)

      value = values[meter]
      next if value.nil?

      unless self.class.readable?(value, meter)
        unreadable[name] = value
        next
      end
      cap = self.class.amount(value, meter)
      return { cap: cap, step: cap, key: name }
    end
    { cap: nil, step: nil, key: nil }
  end

  def ignore_tools(ctx)
    settings = ctx.settings
    settings.key?("ignore_tools") ? Array(settings["ignore_tools"]).map(&:to_s) : DEFAULT_IGNORE
  end

  def warn_share(ctx)
    settings = ctx.settings
    return WARN_AT unless settings.key?("warn_at")

    share = settings["warn_at"]
    share.is_a?(Numeric) && share.positive? ? share : nil
  end

  # Write one meter's cap into the session's state file (the other kept).
  # One there that doesn't read (#state) is written over: logged and said,
  # never a silent replace.
  def save_meter(ctx, session, meter, data)
    path = state_path(ctx, session)
    FileUtils.mkdir_p(File.dirname(path))
    saved = begin
      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      {}
    rescue JSON::ParserError
      nil
    end
    replacing = !saved.is_a?(Hash)
    saved = {} if replacing
    saved[meter] = data.transform_values { |value| whole(value) }
    Samagotchi::AtomicFile.write(path, "#{JSON.generate(saved)}\n")
    replaced(ctx, path) if replacing
    # Resolved again at the next use, from the file now holding the meter.
    @mutex.synchronize { @resolved = nil }
  end

  def replaced(ctx, path)
    ctx.log.warn(:workcap_state_replaced, path: path)
    ctx.notify("work-cap: #{path} didn't read; replaced with the new cap", level: :warn)
  end

  # 800.0 as 800 (a whole cap is saved as an Integer), 2.5 as it is.
  def whole(value) = value.is_a?(Float) && value.finite? && value == value.to_i ? value.to_i : value

  def state_path(ctx, session) = File.join(ctx.data_dir, "sessions", "#{session.gsub(/[^A-Za-z0-9_.-]/, "_")}.json")

  def count(value) = self.class.count(value)

  def first_warning?(meter, key)
    @mutex.synchronize do
      next false if @warned[meter] == key

      @warned[meter] = key
      true
    end
  end

  # Whether +key+ is new for the once-only notice kept in +ivar+ (and keep it).
  def first_time?(ivar, key)
    @mutex.synchronize do
      next false if instance_variable_get(ivar) == key

      instance_variable_set(ivar, key)
      true
    end
  end
end
