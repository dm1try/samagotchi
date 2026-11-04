# frozen_string_literal: true

# The decision-card bundle (docs/bundles.md, The decision-card bundle): in a
# session with objectives, an answer that is long and ends in a question gets a
# card with a short summary and the question, so the question isn't lost at the
# bottom of a long read. The user answers in the composer: the card has no
# buttons, so it invents no options, and it asks nothing of anyone.
#
# The gate costs nothing: the answer's length and tail, read from the event
# (event[:answer]: the stored message may still hold the native loop's thought),
# then the list (ctx.objectives). Only then one side request (ctx.ask_model), on
# a thread: the turn's end isn't held, and the web's answer doesn't wait for it.
# Nothing goes in the conversation: the card is the Bridge's (cards.json, capped),
# and uninstalling the bundle leaves a session as it was.
#
# A card may be late: a one-slot local server answers a side request after the
# running one. A new turn means the user replied or moved on, so it cancels the
# request (which frees the slot for that turn), and a card still to come is
# dropped. One already shown folds to a line at the owner's next turn. The request
# starts at once, ahead of the turn-end warm-up, so that the warm-up is the last
# thing in a one-slot server's slot. The card waits for the turn to be over (the
# hook runs inside it): shown earlier, it would belong to that turn's block, which
# the web collapses.
#
# A failed request shows nothing: it is only logged.
#
# /short is the same seam on demand: the last answer's short version, in a card,
# for any long answer (the web's objectives offer it), its model and its limits
# the card's. Nothing enters the conversation here either.
#
# Settings (config.yml, bundles: decision-card:):
#   min_chars: 1200   how long an answer is long
#   tail_chars: 300   how far from the end the question may be
#   model: nil        a cheap configured model ("host:id", an alias); nil is the session's
#   timeout: 120      seconds the side request may take
#   max_tokens: 300   the side answer's limit
class Plugin
  TITLE = "A question for you"
  SYSTEM = "You read the end of a working session for a busy user. You only report what is written; you don't " \
           "continue the task, and you don't answer the question."
  # What the side request asks, in the three parts #parse reads.
  REQUEST = <<~PROMPT
    The assistant's last answer above may end by asking the user something. The session's objectives are:

    %<list>s

    Reply with exactly these three lines:
    SUMMARY: what the answer says, in one or two plain sentences, at most 40 words
    QUESTION: the question it asks the user, in one sentence, in its own words
    OBJECTIVES: the ids of the objectives that question concerns, or none

    If it asks the user nothing they have to decide, write QUESTION: none. Don't offer options or say which you would pick.
  PROMPT
  PART = /\A[\s*_#>-]*(summary|question|objectives)[\s*_]*:[\s*_]*(.*?)[\s*_]*\z/i
  OBJECTIVE_ID = /\bO\d+\b/i
  SUMMARY_CHARS = 500
  QUESTION_CHARS = 300
  # An :info card with no actions and one line up to 160 characters is a notice row (docs/plugins.md, Cards).
  FOLDED_CHARS = 160
  # A question mark that ends a word (not a URL's), with the marks that may close it.
  SHORT_TITLE = "Short version"
  SHORT_CUT_OFF = "No short version: the session stopped before it came."
  SHORT_BUSY = "a turn is running: /short works on its answer, after this turn"
  # Under the answer. Two paragraphs also keep it a card: a short body alone is a collapsed notice row.
  SHORT_NOTE = "_Asked on demand, not added to the conversation._"
  SHORT_REQUEST = "Give the assistant's last answer above in two or three plain sentences, at most 60 words. Say what it " \
                  "found or did, and anything it asks the user. Add nothing it doesn't say."
  QUESTION_MARK = /[?？؟](?=[\s"'”’»」』)*_\]…]|\.(?:\s|\z)|\z)/
  CODE = /```.*?(?:```|\z)|~~~.*?(?:~~~|\z)|`[^`\n]*`|^(?: {4}|\t)[^\n]*/m
  # What a side answer says for "nothing to decide", however it words it.
  NO_QUESTION = %r{\A(?:none\b|n/a\b|no questions?\b|there (?:is|are) no questions?\b)}i
  TURN_END_POLL = 0.02

  # One answer's side request: the session it is for, and how to cancel it.
  Ask = Data.define(:session_id, :cancel)
  # A card on screen, to fold when the owner's next turn starts.
  Shown = Data.define(:id, :question)
  # What the side answer said: Item ids the list has, in its order.
  Reading = Data.define(:summary, :question, :ids)

  def initialize(settings = {})
    @min_chars = positive(settings["min_chars"]) || 1200
    @tail_chars = positive(settings["tail_chars"]) || 300
    model = settings["model"].to_s.strip
    @model = model.empty? ? nil : model
    @timeout = positive_number(settings["timeout"]) || 120
    @max_tokens = positive(settings["max_tokens"]) || 300
    @mutex = Mutex.new
    @ask = nil
    @shown = []
    @shorts = {}
    @thread = nil
  end

  def register(chi)
    chi.on(:before_turn) { |event, ctx| turn_started(event, ctx) }
    chi.on(:after_turn) { |event, ctx| turn_ended(event, ctx) }
    chi.service(:short_requests, eager: true) do |svc|
      svc.on_stop { @mutex.synchronize { @shorts.keys }.each { |id| end_short(id, SHORT_CUT_OFF) } }
      true
    end
    chi.command("/short", "the last answer's short version, in a card; nothing enters the conversation", anytime: true) do |_args, ctx|
      short(ctx)
    end
  end

  # The side request's thread is done. Nothing in chi waits for it: it is for specs.
  def settle = @thread&.join

  private

  # Any turn makes a request in flight stale, and the slot matters. Only the
  # owner's answers a shown card: a reminder or a child's report has no prompt
  # (a wake runs as a continue), and a participant's has an author.
  def turn_started(event, ctx)
    owner = !event[:author] && !event[:prompt].to_s.strip.empty?
    ask, shown = @mutex.synchronize do
      taken = [@ask, owner ? @shown : []]
      @ask = nil
      @shown = [] if owner
      taken
    end
    ask&.cancel&.cancel!(:new_turn)
    shown.each { |card| fold(ctx, card) }
  end

  def fold(ctx, shown)
    ctx.card(id: shown.id, title: "Asked", body: cut(shown.question, FOLDED_CHARS))
  end

  # On the command's own thread. Not beside a turn: ctx.messages holds that turn so
  # far, so its "last answer" would be interim text.
  # @return [String, nil] what the command answers: only why there is no card
  def short(ctx)
    return SHORT_BUSY if ctx.turn_running?

    messages = ctx.messages
    answer = last_answer(messages) or return "no answer to shorten yet"

    id = ctx.card(title: SHORT_TITLE, body: "…")
    @mutex.synchronize { @shorts[id] = ctx }
    reply = ctx.ask_model(messages: exchange(last_prompt(messages), answer), prompt: SHORT_REQUEST, system: SYSTEM,
                          timeout: @timeout, max_tokens: @max_tokens, model: @model)
    end_short(id, "#{reply.strip}\n\n#{SHORT_NOTE}")
    nil
  rescue StandardError => e
    end_short(id, "No short version: #{e.message}") if id
    nil
  end

  # Once per card, whichever comes first: its answer, or the worker leaving with
  # the request still out (chi waits 3 s for a command, then this service stops,
  # while a card can still reach the UIs). A worker killed outright runs neither:
  # its "…" stays, a one-line row.
  def end_short(id, body)
    ctx = @mutex.synchronize { @shorts.delete(id) } or return

    ctx.card(id: id, title: SHORT_TITLE, body: body)
  end

  # @return [String, nil] the newest non-empty answer's text
  def last_answer(messages)
    found = Array(messages).reverse_each.find do |message|
      %w[model assistant].include?(field(message, :role).to_s) && !field(message, :content).to_s.strip.empty?
    end
    found && field(found, :content).to_s
  end

  def turn_ended(event, ctx)
    return unless event[:status].to_s == "completed"
    # A participant's question is for the participant, on the owner's model; a
    # one-shot run ends before any card is read.
    return if event[:author] || ctx.frontend == :one_shot

    answer = event[:answer]
    return unless answer && answer.length >= @min_chars && question_at_tail?(answer)

    prompt = last_prompt(event[:messages])
    ask = Ask.new(session_id: ctx.session_id, cancel: Samagotchi::CancellationController.new)
    @mutex.synchronize { @ask = ask }
    @thread = Thread.new { ask_for_card(ctx, ask, answer, prompt) }
  end

  # @return [String, nil] the owner's text the turn answers
  def last_prompt(messages)
    prompt = Array(messages).reverse_each.find { |message| field(message, :role).to_s == "user" && field(message, :kind).to_s.empty? }
    prompt && field(prompt, :content).to_s
  end

  def field(message, key) = message[key] || message[key.to_s]

  def question_at_tail?(answer)
    prose = answer.gsub(CODE, "").rstrip
    prose[-[@tail_chars, prose.length].min..].to_s.match?(QUESTION_MARK)
  end

  # On its own thread. Nothing here reaches the user but the card.
  def ask_for_card(ctx, ask, answer, prompt)
    list = ctx.objectives
    return unless list.items.any? { |item| item.status == "active" }

    reply = ctx.ask_model(messages: exchange(prompt, answer), prompt: format(REQUEST, list: list.text), system: SYSTEM,
                          timeout: @timeout, max_tokens: @max_tokens, cancel: ask.cancel, model: @model)
    reading = parse(reply, list)
    return ctx.log.info("no_card", reason: "the side answer named no question and summary") unless reading

    sleep(TURN_END_POLL) while ctx.turn_running? && current?(ask)
    show(ctx, ask, reading, list)
  rescue Samagotchi::Plugin::ModelCancelled
    ctx.log.info("no_card", reason: "a new turn started")
  rescue StandardError => e
    ctx.log.warn("no_card", reason: "#{e.class}: #{e.message}"[0, 300])
  end

  def exchange(prompt, answer)
    [prompt && { role: "user", content: prompt }, { role: "model", content: answer }].compact
  end

  def current?(ask) = @mutex.synchronize { @ask.equal?(ask) }

  # Under the mutex, as a new turn's start is: a card shows before that start
  # takes it (and folds it), or not at all.
  def show(ctx, ask, reading, list)
    @mutex.synchronize do
      next ctx.log.info("no_card", reason: "a new turn started") unless @ask.equal?(ask) && ctx.session_id == ask.session_id

      @ask = nil
      id = ctx.card(title: title(reading), body: body(reading, list))
      @shown << Shown.new(id: id, question: reading.question)
    end
  end

  def title(reading) = reading.ids.empty? ? TITLE : "#{TITLE} · #{reading.ids.join(", ")}"

  def body(reading, list)
    concerns = reading.ids.map { |id| "Concerns #{id} #{list.find(id).text}" }
    [reading.summary, "**#{reading.question}**", *concerns].join("\n\n")
  end

  # The reply's three parts, however a small model marked them up. Lines after a
  # part's own belong to it.
  # @return [Reading, nil] nil without both a summary and a question
  def parse(reply, list)
    parts = Hash.new { |hash, key| hash[key] = [] }
    current = nil
    reply.to_s.each_line do |line|
      if (part = line.strip.match(PART))
        current = part[1].downcase
        parts[current] << part[2]
      elsif current
        parts[current] << line.strip
      end
    end
    summary = clean(parts["summary"], SUMMARY_CHARS)
    question = clean(parts["question"], QUESTION_CHARS)
    return nil if summary.empty? || question.empty? || question.match?(NO_QUESTION)

    Reading.new(summary: summary, question: question, ids: ids(parts["objectives"], list))
  end

  def clean(lines, limit) = cut(lines.join(" ").gsub(/[[:space:]]+/, " ").strip, limit)

  # Display only: a named id the list has and hasn't dropped.
  def ids(lines, list)
    named = lines.join(" ").scan(OBJECTIVE_ID).map(&:upcase)
    list.items.reject { |item| item.status == "dropped" }.map(&:id) & named
  end

  def cut(text, limit) = text.length > limit ? "#{text[0, limit - 1]}…" : text

  def positive_number(value)
    number = Float(value.to_s, exception: false)
    number&.positive? ? number : nil
  end

  def positive(value)
    number = Integer(value.to_s, exception: false)
    number&.positive? ? number : nil
  end
end
