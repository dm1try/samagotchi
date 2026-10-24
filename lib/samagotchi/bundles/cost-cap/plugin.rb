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
#   cap: 3.00       this session's own cap, set with chi --set cost-cap.cap=3
#                   (session_settings: in the manifest); 0/off: none
#   default: 5.00   USD cap for a session with none set; absent/0/off: none
#   child: 2.00     for delegate children (ctx.delegate?); absent: default
#   warn_at: 0.8    the share of the cap that warns; 0/off: no warning
# A cap reads as a number (3, .5, 1e1, "$2" as text too); one that doesn't
# (cap: five) warns the user once and the next key is used, so a typo is
# never a silent "no cap".
#
# State: <data_dir>/sessions/<session id>.json, {"cap": 3.0, "step": 3.0},
# written by /cap and by Continue; "cap": null (or false) is off for the
# session, over the config. Without a file the cap comes from the settings:
# cap:, else child: for a delegate, else default:.
# The cap is resolved once per session id (ctx.delegate? parses the session
# file) and kept until /cap or Continue writes a new one.
require "json"
require "fileutils"

class Plugin
  USAGE = "usage: /cap [N | $N | off] (USD; /cap alone shows the spend)"
  OPTIONS = %w[Continue Stop].freeze
  # For a parent agent's answer (guardrails.parent_answers): Continue
  # spends more, Stop denies; under hard a parent may only Stop.
  EFFECTS = { "Continue" => :spend, "Stop" => :deny }.freeze
  WARN_AT = 0.8
  # A cap as text: 3, 2.5, .5, 1e1, -1 (a negative is none), after a "$".
  NUMBER = /\A-?(?:\d+(?:\.\d*)?|\.\d+)(?:e[-+]?\d+)?\z/i

  def initialize(_settings)
    @mutex = Mutex.new
    @resolved = nil        # {session:, cap:, step:}
    @warned = nil          # [session id, cap] the share warning was given for
    @unknown_warned = nil  # the session id the "can't be enforced" notice was given for
    @unread_warned = nil   # the session id the "isn't a number" notice was given for
    @corrupt_warned = nil  # the session id the "state file doesn't read" notice was given for
  end

  def register(chi)
    chi.on(:before_generation) { |_event, ctx| check(ctx) }
    # Only the "can't be enforced" notice: a turn of one generation (or a
    # session's last) has no next before_generation to give it.
    chi.on(:after_generation) { |_event, ctx| check_known(ctx) }
    chi.command("/cap", "see or set this session's cost cap: /cap, /cap 5, /cap off", anytime: true) do |args, ctx|
      command(args, ctx)
    end
  end

  # The cap in USD (a positive Float) or nil (none, 0, off, false, or a
  # value that isn't a number: .readable? tells them apart).
  def self.amount(value)
    number = number(value)
    number&.positive? ? number : nil
  end

  # +value+ as a finite Float (a number, or text NUMBER reads after a "$"),
  # else nil. "5." gets its 0 first (.float_text: Ruby 3.3's Float wants
  # one); 1e400 (Infinity) is no cap anyone reaches.
  def self.number(value)
    number = case value
             when Numeric then value.to_f
             when String
               text = value.strip.delete_prefix("$")
               Float(float_text(text)) if text.match?(NUMBER)
             end
    number if number&.finite?
  end

  # A NUMBER as Float reads it on every Ruby: a bare point ("5.", "5.e1")
  # gets a 0 after it.
  def self.float_text(text) = text.sub(/\.(?=e|\z)/i, ".0")

  # Whether +value+ reads as a cap or as none: a number (text too), off,
  # false or nil; not "five", true or a list.
  def self.readable?(value)
    case value
    when false, nil then true
    when Numeric then value.finite?
    when String then value.strip.casecmp?("off") || !number(value).nil?
    else false
    end
  end

  # Cents, or up to four decimals under $0.10, so a small cap (/cap 0.003)
  # doesn't read "$0.00 spent of $0.00".
  def self.money(value)
    return format("$%.2f", value) if value.zero? || value.abs >= 0.1

    format("$%.4f", value).sub(/(\.\d\d\d*?)0+\z/, '\1')
  end

  private

  def check(ctx)
    resolved = resolve(ctx)
    unreadable(ctx, resolved)
    corrupt(ctx, resolved)
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

  def check_known(ctx)
    resolved = resolve(ctx)
    return unless resolved[:cap]

    unenforceable(ctx, resolved[:session], resolved[:cap]) unless ctx.cost.known?
  end

  def unenforceable(ctx, session, cap)
    return unless first_time?(:@unknown_warned, session)

    ctx.notify("the #{money(cap)} cap can't be enforced: #{ctx.model || "the model"} reports no cost and has no price",
               level: :warn)
  end

  # Once per session: the settings whose cap didn't read, and what is used.
  def unreadable(ctx, resolved)
    bad = resolved[:unreadable]
    return if bad.nil? || bad.empty? || !first_time?(:@unread_warned, resolved[:session])

    named = bad.map { |key, value| "#{key}: #{value.inspect}" }.join(" and ")
    ctx.notify("cost-cap: #{named} #{bad.size == 1 ? "isn't" : "aren't"} a number or off; #{using(resolved)}",
               level: :warn)
  end

  # Once per session: a state file that is there but doesn't read (not
  # JSON, or not a mapping) holds no /cap cap, so the settings' is used;
  # said rather than a /cap cap silently gone.
  def corrupt(ctx, resolved)
    path = resolved[:corrupt]
    return unless path && first_time?(:@corrupt_warned, resolved[:session])

    ctx.notify("cost-cap: #{path} doesn't read, its /cap cap is ignored; #{using(resolved)}", level: :warn)
  end

  # "using default: ($5.00)", or "no cap".
  def using(resolved) = resolved[:cap] ? "using #{resolved[:key]}: (#{money(resolved[:cap])})" : "no cap"

  def at_cap(ctx, resolved, cost)
    cap = resolved[:cap]
    raised = raised_cap(cap, resolved[:step] || cap, cost.total)
    answer = ctx.ask_user(question: "Cost cap reached: #{money(cost.total)} spent of #{money(cap)}. " \
                                    "Continue raises it to #{money(raised)}.",
                          header: "Cost cap", options: OPTIONS, effects: EFFECTS)
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
    value = self.class.amount(arg)
    return USAGE unless value

    save(ctx, session, "cap" => value, "step" => value)
    "cost-cap: cap set to #{money(value)} (#{money(ctx.cost.total)} spent)"
  rescue StandardError => e
    ctx.log.warn(:cap_command_failed, error: "#{e.class}: #{e.message}")
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

  # The session's cap and step now: the state file's, else the session's
  # own cap: (--set), else child: for a delegate, else default:. Cached per
  # session id.
  def resolve(ctx)
    session = ctx.session_id
    cached = @mutex.synchronize { @resolved }
    return cached if cached && cached[:session] == session

    saved, corrupt = state(ctx, session)
    resolved = { session: session, **(saved || configured(ctx)), corrupt: corrupt }
    @mutex.synchronize { @resolved = resolved }
  end

  # The state file's cap and step ({cap:, step:}), nil without one (or
  # one without a "cap"), and the file's path when it is there but
  # doesn't read (logged; the user is told by #corrupt), else nil.
  def state(ctx, session)
    return [nil, nil] unless session

    path = state_path(ctx, session)
    saved = JSON.parse(File.read(path))
    raise JSON::ParserError, "not a JSON object" unless saved.is_a?(Hash)
    return [nil, nil] unless saved.key?("cap")

    cap = self.class.amount(saved["cap"])
    [{ cap: cap, step: self.class.amount(saved["step"]) || cap }, nil]
  rescue Errno::ENOENT
    [nil, nil]
  rescue JSON::ParserError => e
    ctx.log.warn(:costcap_state_unreadable, path: path, error: e.message.to_s[0, 200])
    [nil, path]
  end

  # The first of cap:, child: (a delegate's) and default: that is set and
  # reads (.readable?); the ones set that don't read are kept for the
  # notice (#unreadable).
  def configured(ctx)
    settings = ctx.settings
    keys = %w[cap child default].select { |key| settings.key?(key) }
    keys.delete("child") if keys.include?("child") && !ctx.delegate?
    bad = keys.reject { |key| self.class.readable?(settings[key]) }
    key = (keys - bad).first
    cap = key && self.class.amount(settings[key])
    { cap: cap, step: cap, key: key, unreadable: bad.to_h { |name| [name, settings[name]] } }
  end

  def warn_share(ctx)
    settings = ctx.settings
    return WARN_AT unless settings.key?("warn_at")

    share = settings["warn_at"]
    share.is_a?(Numeric) && share.positive? ? share : nil
  end

  # A state file there that doesn't read (#state) is written over: logged
  # and said, never a silent replace.
  def save(ctx, session, data)
    path = state_path(ctx, session)
    FileUtils.mkdir_p(File.dirname(path))
    replacing = unreadable_file?(path)
    Samagotchi::AtomicFile.write(path, "#{JSON.generate(data)}\n")
    replaced(ctx, path) if replacing
    cap = self.class.amount(data["cap"])
    @mutex.synchronize { @resolved = { session: session, cap: cap, step: self.class.amount(data["step"]) || cap } }
  end

  # Whether +path+ is there but doesn't read (not JSON, or not a mapping).
  def unreadable_file?(path)
    !JSON.parse(File.read(path)).is_a?(Hash)
  rescue Errno::ENOENT
    false
  rescue JSON::ParserError
    true
  end

  def replaced(ctx, path)
    ctx.log.warn(:costcap_state_replaced, path: path)
    ctx.notify("cost-cap: #{path} didn't read; replaced with the new cap", level: :warn)
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
