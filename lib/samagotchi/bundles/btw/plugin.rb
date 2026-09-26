# The btw bundle (docs/plugins.md, The btw bundle): /btw <question> asks the
# session's model a side question about the conversation. The answer shows
# as a card in every UI and goes nowhere else: the conversation, the saved
# session and the model's next turn never see it. The card's "Keep as
# session" (/btw keep <id>) turns it into a child session that starts from
# the conversation, the question and the answer.
#
# Settings (config.yml, bundles: btw:): max_tokens (the answer's limit,
# default 1024) and timeout (seconds, default 120).
require "securerandom"

class Plugin
  SYSTEM = "Answer the user's question about the conversation below, briefly. The user asks it on the side: " \
           "don't continue the conversation's task, and don't say what you would do next."
  # How many answers /btw keep can still fork: the last ones, for the
  # worker's (or the REPL's) life.
  KEPT = 10
  TITLE_CHARS = 72
  EARLIER = "(About the conversation before the running turn.)"

  def initialize(settings = {})
    @max_tokens = positive(settings["max_tokens"])
    @timeout = positive(settings["timeout"]) || 120
    @answers = {}
    @mutex = Mutex.new
  end

  def register(chi)
    chi.command "/btw", "ask a side question about this conversation; /btw keep <id> makes an answer a session",
                anytime: true do |args, ctx|
      if (keep = args[/\Akeep\s+(\S+)\z/, 1])
        keep(keep, ctx)
      elsif args.empty?
        "usage: /btw <question> — a side answer about this conversation, as a card; nothing is saved"
      else
        ask(args, ctx)
      end
    end
  end

  private

  # A card at once, then the same card with the answer.
  def ask(question, ctx)
    id = SecureRandom.hex(4)
    card_id = "btw-#{id}"
    title = "btw: #{cut(question)}"
    messages = ctx.messages
    about = ctx.messages_partial? ? "\n\n#{EARLIER}" : ""
    ctx.card(id: card_id, title: title, body: "thinking…#{about}")
    answer = begin
      ctx.ask_model(messages: messages, prompt: question, system: SYSTEM, timeout: @timeout, max_tokens: @max_tokens)
    rescue Samagotchi::Plugin::ModelError => e
      ctx.card(id: card_id, title: title, body: "No answer: #{e.message}", level: :warn)
      return nil
    end
    answer = "(the model gave no answer)" if answer.strip.empty?
    remember(id, messages: messages, question: question, answer: answer, card_id: card_id, title: title, about: about)
    ctx.card(id: card_id, title: title, body: "#{answer}#{about}",
             actions: [{ label: "Keep as session", command: "/btw keep #{id}" }])
    nil
  end

  # A child session from the conversation the answer was about, plus the
  # question and the answer.
  def keep(id, ctx)
    entry = @mutex.synchronize { @answers[id] }
    return "btw keep #{id}: expired (answers are kept for the last #{KEPT} questions, while this session's worker runs)" unless entry
    return "btw keep #{id}: already kept as session #{entry[:child]}" if entry[:child]

    seed = entry[:messages] + [{ role: "user", content: entry[:question] }, { role: "model", content: entry[:answer] }]
    child = ctx.sessions.fork(messages: seed, title: "btw: #{entry[:question]}")
    @mutex.synchronize { entry[:child] = child }
    # The answer's card loses its action: it is kept.
    ctx.card(id: entry[:card_id], title: entry[:title], body: "#{entry[:answer]}#{entry[:about]}")
    ctx.card(title: "kept as #{child[0, 8]}",
             body: "A session with this conversation, the question and the answer: `chi --attach #{child}`, " \
                   "or pick it in the web (↳ under this session).")
    nil
  rescue Samagotchi::Plugin::Sessions::Error => e
    "btw keep #{id}: #{e.message}"
  end

  def remember(id, **entry)
    @mutex.synchronize do
      @answers[id] = entry
      @answers.delete(@answers.keys.first) while @answers.size > KEPT
    end
  end

  def cut(text)
    line = text.gsub(/\s+/, " ").strip
    line.length > TITLE_CHARS ? "#{line[0, TITLE_CHARS - 1]}…" : line
  end

  def positive(value)
    number = Integer(value.to_s, exception: false)
    number&.positive? ? number : nil
  end
end
