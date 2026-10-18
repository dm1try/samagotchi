# frozen_string_literal: true

# The cost-cap bundle (docs/plugins.md, The cost-cap bundle): a per-session
# cap on what the session spends (ctx.cost: reported + estimated, side
# requests included). Before each generation it compares the spend with
# the cap: at warn_at of it the user (only) gets one notice, at the cap the
# turn pauses on a question, Continue (the cap goes up by a step) or Stop
# (the turn stops, with a card). With no one to ask it stops. The model
# never sees any of it: no tool, no steer, no prompt text.
#
# Settings (config.yml, bundles: cost-cap:), read at each use from
# ctx.settings, never at load:
#   default: 5.00   USD cap for a session with none set; absent/0/off: none
#   child: 2.00     for delegate children (ctx.delegate?); absent: default
#   warn_at: 0.8    the share of the cap that warns; 0/off: no warning
#
# State: <data_dir>/sessions/<session id>.json, {"cap": 3.0, "step": 3.0},
# written by /cap and by Continue; "cap": null (or false) is off for the
# session, over the config. Without a file the cap comes from the settings.
# The cap is resolved once per session id (ctx.delegate? parses the session
# file) and kept until /cap or Continue writes a new one.
require "json"
require "fileutils"

class Plugin
  USAGE = "usage: /cap [N | $N | off] (USD; /cap alone shows the spend)"
  OPTIONS = %w[Continue Stop].freeze
  WARN_AT = 0.8

  def initialize(_settings)
    @mutex = Mutex.new
    @resolved = nil        # {session:, cap:, step:}
    @warned = nil          # [session id, cap] the share warning was given for
    @unknown_warned = nil  # the session id the "can't be enforced" notice was given for
  end

  def register(chi)
    chi.on(:before_generation) { |_event, ctx| check(ctx) }
    chi.command("/cap", "see or set this session's cost cap: /cap, /cap 5, /cap off", anytime: true) do |args, ctx|
      command(args, ctx)
    end
  end

  # The cap in USD (a positive Float) or nil (none, 0, off, false).
  def self.amount(value)
    number = case value
             when Numeric then value.to_f
             when String then value.strip.delete_prefix("$").then { |s| s.match?(/\A\d+(\.\d+)?\z/) ? s.to_f : nil }
             end
    number&.positive? ? number : nil
  end

  def self.money(value) = format("$%.2f", value)

  private

  def check(ctx)
    resolved = resolve(ctx)
    cap = resolved[:cap]
    return unless cap

    cost = ctx.cost
    return unenforceable(ctx, resolved[:session], cap) unless cost.known?

    total = cost.total
    return at_cap(ctx, resolved, cost) if total >= cap

    share = warn_share(ctx)
    return unless share && total >= share * cap
    return unless first_time?(:@warned, [resolved[:session], cap])

    ctx.notify("#{money(total)} of #{money(cap)} spent (#{(total / cap * 100).floor}%)", level: :warn)
  end

  def unenforceable(ctx, session, cap)
    return unless first_time?(:@unknown_warned, session)

    ctx.notify("the #{money(cap)} cap can't be enforced: #{ctx.model || "the model"} reports no cost and has no price",
               level: :warn)
  end

  def at_cap(ctx, resolved, cost)
    cap = resolved[:cap]
    raised = raised_cap(cap, resolved[:step] || cap, cost.total)
    answer = ctx.ask_user(question: "Cost cap reached: #{money(cost.total)} spent of #{money(cap)}. " \
                                    "Continue raises it to #{money(raised)}.",
                          header: "Cost cap", options: OPTIONS)
    if continue?(answer)
      save(ctx, resolved[:session], "cap" => raised, "step" => resolved[:step] || cap)
      ctx.notify("cap raised to #{money(raised)}")
    else
      stop(ctx, cap, cost)
    end
  end

  # Another step on the cap, as many steps as it takes to pass the spend
  # (a turn that overshot by more than a step asks once, not each step).
  def raised_cap(cap, step, total)
    raised = cap + step
    raised += step while raised <= total
    raised.round(6)
  end

  def continue?(answer)
    return false unless answer

    Array(answer[:selected]).first == "Continue" || Array(answer[:selected_indices]).first&.zero?
  end

  def stop(ctx, cap, cost)
    return unless ctx.stop_turn("cost cap reached (#{money(cost.total)} of #{money(cap)})")

    ctx.card(title: "cost-cap stopped the turn",
             body: "Spent #{breakdown(cost)} of a #{money(cap)} cap.\n\n`/cap N` raises it, `/cap off` removes it.",
             level: :warn)
  end

  def command(args, ctx)
    arg = args.to_s.strip.downcase
    return show(ctx) if arg.empty?

    session = ctx.session_id
    return "cost-cap: no session yet" unless session

    if %w[off 0].include?(arg)
      save(ctx, session, "cap" => nil)
      return "cost-cap: no cap for this session"
    end
    value = arg.match?(/\A\$?\d+(\.\d+)?\z/) ? self.class.amount(arg) : nil
    return USAGE unless value

    save(ctx, session, "cap" => value, "step" => value)
    "cost-cap: cap set to #{money(value)} (#{money(ctx.cost.total)} spent)"
  rescue StandardError => e
    "cost-cap: #{e.message}"
  end

  def show(ctx)
    cost = ctx.cost
    cap = resolve(ctx)[:cap]
    return "cost-cap: no cap (#{money(cost.total)} spent)" unless cap

    line = "cost-cap: #{money(cost.total)} spent of #{money(cap)} (#{parts(cost)})"
    cost.known? ? line : "#{line} (can't be enforced: no cost reported or priced)"
  end

  def parts(cost) = "reported #{money(cost.reported)}, estimated #{money(cost.estimated)}, side #{money(cost.side)}"

  def breakdown(cost) = "#{money(cost.total)} (#{parts(cost)})"

  # The session's cap and step now: the state file's, else child: for a
  # delegate, else default:. Cached per session id.
  def resolve(ctx)
    session = ctx.session_id
    cached = @mutex.synchronize { @resolved }
    return cached if cached && cached[:session] == session

    resolved = { session: session, **(state(ctx, session) || configured(ctx)) }
    @mutex.synchronize { @resolved = resolved }
  end

  def state(ctx, session)
    return nil unless session

    saved = JSON.parse(File.read(state_path(ctx, session)))
    return nil unless saved.is_a?(Hash) && saved.key?("cap")

    cap = self.class.amount(saved["cap"])
    { cap: cap, step: self.class.amount(saved["step"]) || cap }
  rescue Errno::ENOENT, JSON::ParserError
    nil
  end

  def configured(ctx)
    settings = ctx.settings
    return { cap: nil, step: nil } unless settings.key?("default") || settings.key?("child")

    key = settings.key?("child") && ctx.delegate? ? "child" : "default"
    cap = self.class.amount(settings[key])
    { cap: cap, step: cap }
  end

  def warn_share(ctx)
    settings = ctx.settings
    return WARN_AT unless settings.key?("warn_at")

    share = settings["warn_at"]
    share.is_a?(Numeric) && share.positive? ? share : nil
  end

  def save(ctx, session, data)
    path = state_path(ctx, session)
    FileUtils.mkdir_p(File.dirname(path))
    Samagotchi::AtomicFile.write(path, "#{JSON.generate(data)}\n")
    cap = self.class.amount(data["cap"])
    @mutex.synchronize { @resolved = { session: session, cap: cap, step: self.class.amount(data["step"]) || cap } }
  end

  def state_path(ctx, session) = File.join(ctx.data_dir, "sessions", "#{session.gsub(/[^A-Za-z0-9_.-]/, "_")}.json")

  def money(value) = self.class.money(value)

  # Whether +key+ is new for the once-only notice kept in +ivar+ (and keep it).
  def first_time?(ivar, key)
    @mutex.synchronize do
      next false if instance_variable_get(ivar) == key

      instance_variable_set(ivar, key)
      true
    end
  end
end
