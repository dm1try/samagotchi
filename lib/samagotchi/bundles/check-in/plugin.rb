# frozen_string_literal: true

# The check-in bundle (docs/plugins.md, The check-in bundle): a turn that
# has made many tool calls without answering gets checked on. After `after`
# tool calls (then every `every` more) it asks the user with a card (Nudge /
# Keep going / Stop), nudges the model by itself, or only says so.
#
# A nudge is ctx.steer: the message joins the running turn at its next
# boundary as its own user message, so the model reads it before its next
# step. It never starts a turn, and one that arrives after the model's
# final answer is dropped: the card's Nudge then says so at the turn's end
# (after_turn's messages have no steer with its text).
#
# One nudge per check-in: a second Nudge (a repeat click, a stale card's
# button, a typed /checkin nudge) for the same check-in only says it was
# already nudged; before the turn's first check-in, one nudge in all.
#
# The count is per turn: before_turn resets it (and closes a card left open
# by a turn that failed or was interrupted, where after_turn doesn't fire);
# steering merged mid-turn does not. The /checkin commands are anytime ones
# (a card's actions run while the turn goes on), so the state is behind a
# Mutex.
#
# What /checkin changes (on/off, mode, the threshold) is the session's: it
# is saved in the bundle's data dir (sessions/<id>.json) and read back
# when the session comes back (a worker's restart), before its first turn
# or command. Another session starts from the settings.
#
# Each check-in also asks System 1 `check-in.progress` (docs/system-one.md),
# off until the user sets a mode for it: the turn's prompt, the calls since
# the last check-in and the count and elapsed time go, on a side thread, to
# the cheap judgment model. Nothing is done with the answer: it is saved,
# and what the user then did with the card is saved as a label on that run.
# The card, the nudge and the notify are the same either way.
#
# Settings (config.yml, bundles: check-in:):
#   after: 50          tool calls in one turn before the first check-in
#   every: 50          then again every this many more
#   mode: ask          ask | nudge | notify
#   message: "..."     what a nudge says; {calls} is the count
#   ignore_tools: [task_wait, task_get, delegate_result]
require "fileutils"
require "json"
require "securerandom"

class Plugin
  MODES = %w[ask nudge notify].freeze
  DEFAULT_MESSAGE = "You've made {calls} tool calls in this turn without answering. Say briefly what you've found " \
                    "so far and what's left, then answer now or continue."
  DEFAULT_IGNORE = %w[task_wait task_get delegate_result].freeze
  LAST_TOOLS = 5
  USAGE = "usage: /checkin [on|off|<calls>|mode ask|nudge|notify|nudge|later|stop]"
  # The audit judgment (docs/plugins.md, Judgments): one noul question per
  # check-in, answered on a side thread and never acted on.
  PROGRESS = "progress"
  PROGRESS_QUESTION = "Is this turn still making progress toward what the user asked?"
  # The calls since the last check-in, each cut as it is captured and kept
  # together under about 4 KB (the oldest go first).
  CALL_CHARS = 120
  RESULT_CHARS = 200
  CALLS_TOTAL = 4096

  def initialize(settings = {})
    @after = positive(settings["after"]) || 50
    @every = positive(settings["every"]) || @after
    @mode = MODES.include?(settings["mode"].to_s) ? settings["mode"].to_s : "ask"
    message = settings["message"].to_s.strip
    @message = message.empty? ? DEFAULT_MESSAGE : message
    @ignore = settings.key?("ignore_tools") ? Array(settings["ignore_tools"]).map(&:to_s) : DEFAULT_IGNORE
    @enabled = true
    @defaults = { "enabled" => @enabled, "mode" => @mode, "after" => @after, "every" => @every }
    @session = :none # the session whose /checkin state is loaded
    @mutex = Mutex.new
    reset
  end

  def register(chi)
    # An older chi has no judgments; the check-in itself is the same there.
    @declared = chi.respond_to?(:judgment)
    chi.judgment PROGRESS, questions: { PROGRESS => { type: "noul", instructions: PROGRESS_QUESTION } } if @declared

    chi.on(:before_turn) { |event, ctx| before_turn(event, ctx) }
    chi.on(:after_tool_call) { |event, ctx| after_tool_call(event, ctx) }
    chi.on(:after_turn) { |event, ctx| after_turn(event, ctx) }
    chi.command "/checkin", "check on a long turn: status, on|off, <calls>, mode ask|nudge|notify, nudge, later, stop",
                anytime: true do |args, ctx|
      command(args.to_s.strip.downcase, ctx)
    end
  end

  private

  # --- the turn --------------------------------------------------------------

  def reset
    @count = 0
    @next_at = @after
    @started = monotonic
    @tools = []
    @card_id = nil  # this turn's card, once shown
    @card_open = false
    @nudge = nil    # the card's Nudge this turn: { text:, count: }
    @checked_in = nil # the count at this turn's latest check-in
    @nudged_for = nil # the check-in (its count, :none before one) nudged
    @prompt = nil   # the owner's prompt, for the judgment
    @calls_since = [] # the calls since the last check-in, for the judgment
    @calls_bytes = 0
    @run = nil      # the latest check-in's run, for its labels
  end

  def before_turn(event, ctx)
    close_card(ctx, "The turn ended after #{calls} tool calls.")
    @mutex.synchronize do
      load_session(ctx)
      reset
      # A continue, a wake or a reminder has no prompt of its own, and a
      # participant's turn says nothing about the owner's: the judgment gets
      # none then.
      @prompt = ctx.turn_author ? nil : event[:prompt]
    end
  end

  def after_tool_call(event, ctx)
    tool = event[:tool].to_s
    return if @ignore.include?(tool)

    due = @mutex.synchronize do
      load_session(ctx)
      @count += 1
      @tools = (@tools + [tool]).last(LAST_TOOLS)
      note_call(event)
      next nil unless @enabled && @count >= @next_at

      @next_at = @count + @every
      @checked_in = @count
      [@count, @mode]
    end
    return unless due

    check_in(ctx, *due)
    ask_progress(ctx)
  end

  def check_in(ctx, count, mode)
    case mode
    when "nudge"
      text = message(count)
      if ctx.steer(text)
        @mutex.synchronize do
          @nudge = { text: text, count: count }
          @nudged_for = count
        end
        ctx.notify("nudged the model after #{count} tool calls")
      end
    when "notify"
      ctx.notify("#{count} tool calls in this turn, no answer yet")
    else
      show_card(ctx, count)
    end
  end

  def after_turn(event, ctx)
    label(ctx, "turn_stopped", by: "turn", strength: nil) if close_card(ctx, "The turn ended after #{calls} tool calls.")

    nudge_not_sent(event, ctx)
  end

  # A nudge that was accepted but dropped before it joined the turn (the
  # model answered first, or the turn was stopped): the card says so, or,
  # for a mode nudge (no card), a notice does.
  def nudge_not_sent(event, ctx)
    id, nudge = @mutex.synchronize { [@card_id, @nudge] }
    return unless nudge
    return if steered?(event[:messages], nudge[:text])

    first = event[:status].to_s == "canceled" ? "The turn ended first" : "The answer came first"
    if id
      ctx.card(id: id, title: "check-in", body: "#{first}; nudge not sent.")
    else
      ctx.notify("#{first}; nudge not sent.", level: :warn)
    end
  end

  # Whether this turn's messages (after its last prompt) have the steer.
  def steered?(messages, text)
    Array(messages).reverse_each do |message|
      next unless message.is_a?(Hash)

      role = (message[:role] || message["role"]).to_s
      kind = (message[:kind] || message["kind"]).to_s
      return true if kind == "steer" && (message[:content] || message["content"]).to_s.strip == text.strip
      # A user line merged into the turn (kind input) is part of it: look past it.
      return false if role == "user" && !%w[steer input].include?(kind)
    end
    false
  end

  # One card per turn: a later check-in updates it in place.
  def show_card(ctx, count)
    id, body = @mutex.synchronize do
      @card_id ||= "check-in-#{SecureRandom.hex(4)}"
      @card_open = true
      [@card_id, "#{elapsed} in this turn. Last tools: #{@tools.join(", ")}."]
    end
    ctx.card(id: id, title: "#{count} tool calls, no answer yet", body: body,
             actions: [{ label: "Nudge", command: "/checkin nudge" },
                       { label: "Keep going", command: "/checkin later" },
                       { label: "Stop", command: "/checkin stop" }])
  end

  # The open card, replaced by one without actions (stale buttons go).
  # @return [Boolean] whether there was one
  def close_card(ctx, body)
    id = @mutex.synchronize do
      next nil unless @card_open

      @card_open = false
      @card_id
    end
    return false unless id

    ctx.card(id: id, title: "check-in", body: body)
    true
  end

  # --- the progress judgment (audit) ---------------------------------------

  # Every counted call since the last check-in, in the words System 1 sees:
  # the tool, what it was asked for, what it said. Cut here, so the state
  # stays near 4 KB whatever a tool returned (docs/system-one.md: this is
  # tool output reaching System 1, which approvals and context never send).
  def note_call(event)
    entry = "#{event[:tool]} #{cut(call_args(event[:call]), CALL_CHARS)} -> #{cut(event[:result] || event[:output], RESULT_CHARS)}"
    @calls_since << entry
    @calls_bytes += entry.bytesize
    @calls_bytes -= @calls_since.shift.bytesize while @calls_bytes > CALLS_TOTAL && @calls_since.size > 1
  end

  def call_args(call)
    args = call.is_a?(Hash) ? (call[:arguments] || call["arguments"] || call) : call
    return args if args.is_a?(String)

    # The tool's name is already in the entry and nil fields say nothing:
    # the cut should keep what the call asked for.
    args = args.compact.except(:name, "name") if args.is_a?(Hash)
    JSON.generate(args)
  rescue StandardError
    args.to_s
  end

  def cut(text, limit)
    text = text.to_s
    text.length > limit ? "#{text[0, limit]}…" : text
  end

  # The ask, on its own thread. Nothing reads the answer: the turn and the
  # card are what they are with the judgment off.
  def ask_progress(ctx)
    return unless @declared

    state = @mutex.synchronize do
      state = { prompt: @prompt, calls: @count, elapsed_s: (monotonic - @started).round, tools: @calls_since.dup }
      @calls_since = []
      @calls_bytes = 0
      state
    end
    run = ctx.judge_later(PROGRESS, state: state)
    @mutex.synchronize { @run = run }
  end

  # What the user did with the card, saved on this turn's latest check-in's
  # run: raw words, mapped only at analysis, since a Nudge asks for a status
  # rather than a verdict and Keep going may be habit. A run that was never
  # saved (the judgment off, no host) labels nothing.
  def label(ctx, value, by: "card", strength: "weak")
    return false unless @declared

    ctx.judgments.label(@mutex.synchronize { @run }, value, by: by, strength: strength)
  end

  # --- /checkin --------------------------------------------------------------

  def command(args, ctx)
    @mutex.synchronize { load_session(ctx) }
    case args
    when "" then status
    when "on", "off"
      @mutex.synchronize do
        @enabled = args == "on"
        save_session(ctx)
      end
      "check-in is #{args} for this session"
    when /\A\d+\z/
      threshold(Integer(args), ctx)
    when /\Amode\s+(\S+)\z/
      mode = Regexp.last_match(1)
      return "check-in: unknown mode #{mode} (ask, nudge or notify)" unless MODES.include?(mode)

      @mutex.synchronize do
        @mode = mode
        save_session(ctx)
      end
      "check-in mode is #{mode} for this session"
    when "nudge" then nudge(ctx)
    when "later" then later(ctx)
    when "stop" then stop(ctx)
    else USAGE
    end
  end

  def status
    @mutex.synchronize do
      state = @enabled ? "on" : "off"
      "check-in is #{state}: mode #{@mode}, after #{@after} tool calls, then every #{@every}; " \
        "this turn: #{@count} tool calls"
    end
  end

  # For this session: check in at +n+ calls and every +n+ after; a turn
  # already past it is checked on +n+ calls from now.
  def threshold(n, ctx)
    return "check-in: the threshold must be at least 1" unless n.positive?

    @mutex.synchronize do
      @after = @every = n
      @next_at = n > @count ? n : @count + n
      save_session(ctx)
    end
    "check-in after #{n} tool calls, then every #{n}, for this session"
  end

  # At most one nudge per check-in; the slot is taken before the steer (two
  # clicks race on the anytime command's threads) and given back when no
  # turn took it.
  def nudge(ctx)
    count, key, earlier = @mutex.synchronize do
      key = @checked_in || :none
      next [nil, nil, @nudge&.dig(:count) || @count] if @nudged_for == key

      @nudged_for = key
      [@count, key, nil]
    end
    return "check-in: already nudged at #{earlier} tool calls" if earlier

    text = message(count)
    unless ctx.steer(text)
      @mutex.synchronize { @nudged_for = nil if @nudged_for == key }
      return "check-in: no turn running"
    end

    @mutex.synchronize { @nudge = { text: text, count: count } }
    label(ctx, "nudge") if card_open?
    close_card(ctx, "Nudged the model at #{count} tool calls.")
    nil
  end

  def later(ctx)
    at = @mutex.synchronize { @next_at }
    return "check-in: no check-in open" unless close_card(ctx, "Kept going; the next check-in is at #{at} tool calls.")

    label(ctx, "keep_going")
    nil
  end

  def stop(ctx)
    return "check-in: no turn running" unless ctx.stop_turn("stopped from check-in")

    label(ctx, "stop") if card_open?
    close_card(ctx, "Stopped the turn at #{calls} tool calls.")
    nil
  end

  # --- the session's /checkin state (under @mutex) ---------------------------

  # The current session's state, when the session isn't the one loaded:
  # its saved file over the settings.
  def load_session(ctx)
    id = ctx.session_id
    return if id == @session

    @session = id
    state = @defaults.merge(read_state(ctx, id))
    @enabled = state["enabled"] == true
    @mode = MODES.include?(state["mode"]) ? state["mode"] : @defaults["mode"]
    @after = positive(state["after"]) || @defaults["after"]
    @every = positive(state["every"]) || @defaults["every"]
    @next_at = @after if @count.zero?
  end

  def read_state(ctx, id)
    return {} unless id

    data = JSON.parse(File.read(state_path(ctx, id)))
    data.is_a?(Hash) ? data : {}
  rescue SystemCallError, JSON::ParserError
    {}
  end

  # Written aside and renamed: a reader never sees half a file.
  def save_session(ctx)
    id = ctx.session_id
    return unless id

    path = state_path(ctx, id)
    FileUtils.mkdir_p(File.dirname(path))
    temp = "#{path}.#{Process.pid}.tmp"
    File.write(temp, JSON.generate({ "enabled" => @enabled, "mode" => @mode, "after" => @after, "every" => @every }))
    File.rename(temp, path)
  rescue SystemCallError => e
    ctx.log.warn("check_in_state_not_saved", msg: e.message) if ctx.respond_to?(:log)
  end

  def state_path(ctx, id) = File.join(ctx.data_dir, "sessions", "#{id.to_s.gsub(/[^A-Za-z0-9_.-]+/, "_")}.json")

  # --- helpers ---------------------------------------------------------------

  def calls = @mutex.synchronize { @count }

  def card_open? = @mutex.synchronize { @card_open }

  def message(count) = @message.gsub("{calls}", count.to_s)

  def elapsed
    seconds = (monotonic - @started).round
    seconds < 60 ? "#{seconds}s" : "#{seconds / 60}m #{seconds % 60}s"
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def positive(value)
    number = Integer(value.to_s, exception: false)
    number&.positive? ? number : nil
  end
end
