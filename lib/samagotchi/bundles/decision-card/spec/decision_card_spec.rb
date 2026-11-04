# frozen_string_literal: true

require "samagotchi/testing/rspec"

# The decision-card plugin on its own, through the bundle test kit;
# spec/samagotchi/plugin/decision_card_bundle_spec.rb installs it and runs real turns.
RSpec.describe "The decision-card plugin", :bundle do
  LIST = { "next" => 3, "items" => [{ "id" => "O1", "text" => "Two coffees", "status" => "done" },
                                    { "id" => "O2", "text" => "Stops before checkout", "status" => "active" }] }.freeze
  REPLY = "SUMMARY: The cart holds two coffees and stops before checkout.\n" \
          "QUESTION: Which filter size do you want?\nOBJECTIVES: O2"

  def note(payload = LIST)
    { role: "system", kind: "note", content: "[OBJECTIVES…]", note_id: "n1", source: "objectives",
      objectives: payload }
  end

  def long(tail = "Which filter size do you want?") = "#{"The cart is ready. " * 80}\n\n#{tail}"

  def conversation(answer: long, list: note)
    [list, { role: "user", content: "Order the coffee" }, { role: "model", content: answer }].compact
  end

  def plugin(settings = {}, **host)
    shipped_bundle("decision-card", settings: settings, host: { session_id: "s1", running: false, **host })
  end

  # What chi gives as event[:answer]: the turn's answer, without its thought.
  def answer_in(messages)
    last = messages.last
    last[:content] || last["content"] if (last[:role] || last["role"]) == "model"
  end

  # A turn's end: the hook, then its thread's end.
  def end_turn(bundle, status: "completed", messages: conversation, answer: answer_in(messages), **event)
    bundle.set(messages: messages)
    bundle.fire(:after_turn, status: status, messages: messages, answer: answer, **event)
    bundle.plugin.settle
  end

  describe "the gate" do
    it "shows a card for a list session's long answer with a question at its tail" do
      bundle = plugin
      bundle.model_answers << REPLY
      end_turn(bundle)

      expect(bundle.model_requests.size).to eq(1)
      expect(bundle.cards.size).to eq(1)
    end

    it "asks no model with no list" do
      bundle = plugin
      end_turn(bundle, messages: conversation(list: nil))

      expect(bundle.model_requests).to be_empty
      expect(bundle.cards).to be_empty
    end

    it "asks no model when every objective is done or dropped" do
      bundle = plugin
      all_done = { "next" => 2, "items" => [{ "id" => "O1", "text" => "x", "status" => "done" }] }
      end_turn(bundle, messages: conversation(list: note(all_done)))

      expect(bundle.model_requests).to be_empty
    end

    it "asks no model for a short answer" do
      bundle = plugin
      end_turn(bundle, messages: conversation(answer: "Which one?"))

      expect(bundle.model_requests).to be_empty
    end

    it "counts a long answer from min_chars" do
      question = " Which?"
      at = ("x" * (1200 - question.length)) + question
      under = at[1..]

      bundle = plugin
      end_turn(bundle, messages: conversation(answer: under))
      expect(bundle.model_requests).to be_empty

      bundle.model_answers << REPLY
      end_turn(bundle, messages: conversation(answer: at))
      expect(bundle.model_requests.size).to eq(1)

      small = plugin({ "min_chars" => 5 })
      small.model_answers << REPLY
      end_turn(small, messages: conversation(answer: "Which one?"))
      expect(small.model_requests.size).to eq(1)
    end

    it "asks no model with no question at the tail" do
      bundle = plugin
      end_turn(bundle, messages: conversation(answer: "Did it work? Yes. #{"It works. " * 200}"))

      expect(bundle.model_requests).to be_empty
    end

    it "takes the tail from tail_chars" do
      answer = "Which one? #{"It works. " * 200}"
      bundle = plugin({ "tail_chars" => answer.length })
      bundle.model_answers << REPLY
      end_turn(bundle, messages: conversation(answer: answer))

      expect(bundle.model_requests.size).to eq(1)
    end

    it "doesn't take a URL's, an inline code's or a code block's ? for a question" do
      [long("See https://example.com/a?b=1 for it."), long("Use `empty?` here."), long("```ruby\nx.empty?\n```")].each do |answer|
        bundle = plugin
        end_turn(bundle, messages: conversation(answer: answer))
        expect(bundle.model_requests).to be_empty, answer[-40..]
      end
    end

    it "doesn't take a ~~~ block's or an indented line's ? for a question" do
      [long("~~~\nWhich one?\n~~~"), long("Run this:\n\n    Which one?\n"), long("Run this:\n\n\tWhich one?")].each do |answer|
        bundle = plugin
        end_turn(bundle, messages: conversation(answer: answer))
        expect(bundle.model_requests).to be_empty, answer[-40..]
      end
    end

    it "doesn't take a ? inside a word followed by a dot for a question" do
      bundle = plugin
      end_turn(bundle, messages: conversation(answer: long("Call x?.y on it.")))
      expect(bundle.model_requests).to be_empty
    end

    it "takes a question in marks or in another script's mark" do
      [long("**Which size?**"), long("Which size? (or neither)"), long("どちらにしますか？"), long("أي واحد؟"),
       long("«Which size?»"), long("「どちら?」"), long("Which size?…"), long("Which size?.")].each do |answer|
        bundle = plugin
        bundle.model_answers << REPLY
        end_turn(bundle, messages: conversation(answer: answer))
        expect(bundle.model_requests.size).to eq(1), answer[-40..]
      end
    end

    it "asks no model for a stopped turn" do
      bundle = plugin
      end_turn(bundle, status: "canceled")

      expect(bundle.model_requests).to be_empty
    end

    it "asks no model when the turn has no answer (it ran out of steps, say)" do
      bundle = plugin
      end_turn(bundle, answer: nil)

      expect(bundle.model_requests).to be_empty
    end

    # The native loop stores the model's content with its thought block, and
    # strips it only at the next turn: the gate reads the event's answer.
    it "doesn't count a thought kept in the stored message" do
      thought = "<|channel>thought\n#{"Thinking it over. " * 100}Is it?<channel|>"
      short = plugin
      end_turn(short, messages: conversation(answer: "#{thought}Which one?"), answer: "Which one?")
      expect(short.model_requests).to be_empty

      done = plugin
      end_turn(done, messages: conversation(answer: "#{thought}#{"Done. " * 300}"), answer: "Done. " * 300)
      expect(done.model_requests).to be_empty
    end

    it "sends the side request the answer without its thought" do
      thought = "<|channel>thought\nSECRET PLAN<channel|>"
      bundle = plugin
      bundle.model_answers << REPLY
      end_turn(bundle, messages: conversation(answer: "#{thought}#{long}"), answer: long)

      expect(bundle.model_requests.last.request.last[:content]).to include("Which filter size").and(satisfy { |text| !text.include?("SECRET") })
    end

    it "reads a saved session's string keys" do
      bundle = plugin
      bundle.model_answers << REPLY
      saved = conversation.map { |message| message.transform_keys(&:to_s) }
      end_turn(bundle, messages: saved)

      expect(bundle.model_requests.last.request.last[:content]).to include("Order the coffee")
    end

    it "asks no model for a participant's turn" do
      bundle = plugin
      end_turn(bundle, author: "p:p_1")

      expect(bundle.model_requests).to be_empty
    end

    it "asks no model in a one-shot run: nobody is left to read a card" do
      bundle = plugin(frontend: :non_interactive)
      end_turn(bundle)

      expect(bundle.model_requests).to be_empty
    end
  end

  describe "the request" do
    it "passes the list in the prompt, the turn's prompt and answer as the messages" do
      bundle = plugin
      bundle.model_answers << REPLY
      end_turn(bundle, messages: [note, { role: "user", content: "an older ask" }, { role: "model", content: "older" },
                                  *conversation(list: nil)])

      request = bundle.model_requests.last
      user = request.request.last[:content]
      expect(user).to include("O2 Stops before checkout", "O1 [done] Two coffees", "Order the coffee", "The cart is ready")
      expect(user).not_to include("an older ask")
      expect(request.max_tokens).to eq(300)
      expect(request.timeout).to eq(120.0)
      expect(request.model).to be_nil
      expect(request.source).to eq("decision-card")
    end

    it "takes model, timeout and max_tokens from the settings" do
      bundle = plugin({ "model" => "cheap:tiny", "timeout" => 7, "max_tokens" => 50 })
      bundle.model_answers << REPLY
      end_turn(bundle)

      request = bundle.model_requests.last
      expect([request.model, request.timeout, request.max_tokens]).to eq(["cheap:tiny", 7.0, 50])
    end

    it "takes a fractional timeout" do
      bundle = plugin({ "timeout" => 1.5 })
      bundle.model_answers << REPLY
      end_turn(bundle)

      expect(bundle.model_requests.last.timeout).to eq(1.5)
    end

    it "asks for no options" do
      bundle = plugin
      bundle.model_answers << REPLY
      end_turn(bundle)

      expect(bundle.model_requests.last.request.last[:content]).to include("Don't offer options")
    end
  end

  describe "the card" do
    def card_for(reply)
      bundle = plugin
      bundle.model_answers << reply
      end_turn(bundle)
      bundle
    end

    it "has the summary and the question, tied to the objective the model names, with no actions" do
      card = card_for(REPLY).cards.last

      expect(card[:title]).to eq("A question for you · O2")
      expect(card[:body]).to eq("The cart holds two coffees and stops before checkout.\n\n" \
                                "**Which filter size do you want?**\n\nConcerns O2 Stops before checkout")
      expect(card[:actions]).to eq([])
      expect(card[:level]).to eq(:info)
    end

    it "has no tie when the model names none, or an id the list doesn't have, or a dropped one" do
      dropped = { "next" => 3, "items" => [{ "id" => "O1", "text" => "x", "status" => "dropped" },
                                           { "id" => "O2", "text" => "y", "status" => "active" }] }
      bundle = plugin
      bundle.model_answers << "SUMMARY: s\nQUESTION: q?\nOBJECTIVES: O1, O9, none"
      end_turn(bundle, messages: conversation(list: note(dropped)))

      expect(bundle.cards.last).to include(title: "A question for you", body: "s\n\n**q?**")
    end

    it "reads a reply in marks, lower case and over several lines" do
      card = card_for("Here you go:\n**summary:** one\ntwo\n\n**Question**: which?\n- objectives: o2").cards.last

      expect(card[:title]).to eq("A question for you · O2")
      expect(card[:body]).to start_with("one two\n\n**which?**")
    end

    it "shows nothing when the model says no question is asked, or leaves a part out" do
      ["SUMMARY: s\nQUESTION: none\nOBJECTIVES: none", "SUMMARY: s\nQUESTION: No question.", "SUMMARY: s\nQUESTION: N/A",
       "SUMMARY: s\nQUESTION: There is no question for the user.", "SUMMARY: s\nQUESTION: **None.**",
       "QUESTION: q?", "SUMMARY: s", "no idea", ""].each do |reply|
        bundle = card_for(reply)
        expect(bundle.cards).to be_empty, reply
        expect(bundle.notices).to be_empty, reply
      end
    end

    it "keeps a real question that starts like a refusal" do
      card = card_for("SUMMARY: s\nQUESTION: Nonetheless, which size?").cards.last

      expect(card[:body]).to include("Nonetheless, which size?")
    end

    it "caps what a long-winded model says" do
      card = card_for("SUMMARY: #{"s" * 2000}\nQUESTION: #{"q" * 2000}").cards.last

      expect(card[:body].length).to be < 1000
      expect(card[:body]).to include("…")
    end
  end

  describe "a late card" do
    # The side answer comes while +during+ runs.
    def asked(bundle, during)
      bundle.model_answers << lambda { |_request|
        during.call
        REPLY
      }
      end_turn(bundle)
    end

    it "is dropped when a new turn started while it was asked" do
      bundle = plugin
      asked(bundle, -> { bundle.fire(:before_turn, prompt: "the next ask") })

      expect(bundle.cards).to be_empty
    end

    it "is dropped and cancelled by a turn the owner didn't start too: the slot matters" do
      bundle = plugin
      cancels = []
      bundle.model_answers << lambda { |request|
        request.cancel.on_cancel { |reason| cancels << reason }
        bundle.fire(:before_turn, prompt: nil)
        raise Samagotchi::Plugin::ModelCancelled, "the request was cancelled"
      }
      end_turn(bundle)

      expect(cancels.size).to eq(1)
      expect(bundle.cards).to be_empty
    end

    it "cancels the request when a new turn starts: a one-slot server is free for the turn" do
      bundle = plugin
      cancels = []
      bundle.model_answers << lambda { |request|
        request.cancel.on_cancel { |reason| cancels << reason }
        bundle.fire(:before_turn, prompt: "next")
        raise Samagotchi::Plugin::ModelCancelled, "the request was cancelled"
      }
      end_turn(bundle)

      expect(cancels.size).to eq(1)
      expect(bundle.cards).to be_empty
      expect(bundle.notices).to be_empty
    end

    it "leaves the next turn's own card alone" do
      bundle = plugin
      bundle.model_answers << REPLY
      end_turn(bundle)
      bundle.fire(:before_turn, prompt: "next")
      bundle.model_answers << REPLY
      end_turn(bundle)

      expect(bundle.cards.map { |card| card[:title] }.last).to start_with("A question for you")
    end

    it "is dropped when the session moved on" do
      bundle = plugin
      asked(bundle, -> { bundle.set(session_id: "s2") })

      expect(bundle.cards).to be_empty
    end
  end

  describe "a shown card" do
    it "folds to a line when the next turn starts: the question is answered or passed" do
      bundle = plugin
      bundle.model_answers << REPLY
      end_turn(bundle)
      id = bundle.cards.last[:id]

      bundle.fire(:before_turn, prompt: "the small one")

      expect(bundle.cards.size).to eq(2)
      expect(bundle.cards.last).to include(id: id, title: "Asked", body: "Which filter size do you want?")
      expect(bundle.cards.last[:actions]).to eq([])
    end

    # The coordinator is this bundle's main audience: a child's report isn't an answer.
    it "stays open through a turn the owner didn't start" do
      bundle = plugin
      bundle.model_answers << REPLY
      end_turn(bundle)

      bundle.fire(:before_turn, prompt: nil)
      bundle.fire(:before_turn, prompt: "")
      bundle.fire(:before_turn, prompt: "a participant's", author: "p:p_1")
      expect(bundle.cards.size).to eq(1)

      bundle.fire(:before_turn, prompt: "the small one")
      expect(bundle.cards.last).to include(title: "Asked")
    end

    it "folds every card still open at the owner's next turn" do
      bundle = plugin
      2.times do
        bundle.model_answers << REPLY
        end_turn(bundle)
        bundle.fire(:before_turn, prompt: nil)
      end
      ids = bundle.cards.map { |card| card[:id] }

      bundle.fire(:before_turn, prompt: "the small one")

      expect(bundle.cards.last(2).map { |card| [card[:id], card[:title]] }).to contain_exactly([ids.first, "Asked"], [ids.last, "Asked"])
    end

    it "folds once" do
      bundle = plugin
      bundle.model_answers << REPLY
      end_turn(bundle)
      2.times { bundle.fire(:before_turn, prompt: "again") }

      expect(bundle.cards.size).to eq(2)
    end

    it "folds to a line short enough for a notice" do
      bundle = plugin
      bundle.model_answers << "SUMMARY: s\nQUESTION: #{"q" * 280}?"
      end_turn(bundle)
      bundle.fire(:before_turn, prompt: "next")

      expect(bundle.cards.last[:body].length).to be <= 160
    end
  end

  describe "a failure" do
    def failed_with(error)
      bundle = plugin
      bundle.model_answers << error
      end_turn(bundle)
      bundle
    end

    it "shows nothing and tells no one on a model error" do
      bundle = failed_with(Samagotchi::Plugin::ModelError.new("unreachable"))

      expect(bundle.cards).to be_empty
      expect(bundle.notices).to be_empty
    end

    it "shows nothing on anything else, a model: naming nothing among them" do
      bundle = failed_with(ArgumentError.new("ask_model: unknown model"))

      expect(bundle.cards).to be_empty
      expect(bundle.notices).to be_empty
    end
  end

  # The hook fires before the turn is over. A card shown then would land in the
  # turn's closed block, so the card waits for the end. The request doesn't: on a
  # one-slot server the next turn's warm-up should be the last thing in the slot.
  def polls_while_running(bundle)
    polls = Queue.new
    allow(bundle.ctx).to receive(:turn_running?).and_wrap_original do |original|
      polls << true
      original.call
    end
    polls
  end

  it "asks at once and shows only once the turn is over" do
    bundle = plugin(running: true)
    polls = polls_while_running(bundle)
    bundle.model_answers << REPLY
    bundle.set(messages: conversation)
    bundle.fire(:after_turn, status: "completed", messages: conversation, answer: long)

    wait_for("the plugin to look at the turn twice") { polls.size >= 2 }
    expect(bundle.model_requests.size).to eq(1)
    expect(bundle.cards).to be_empty

    bundle.set(running: false)
    bundle.plugin.settle
    expect(bundle.cards.size).to eq(1)
  end

  it "stops waiting for the turn's end when the next one takes over, and shows nothing" do
    bundle = plugin(running: true)
    polls = polls_while_running(bundle)
    bundle.model_answers << REPLY
    bundle.set(messages: conversation)
    bundle.fire(:after_turn, status: "completed", messages: conversation, answer: long)
    wait_for("the plugin to look at the turn") { polls.size >= 1 }
    bundle.fire(:before_turn, prompt: "next")
    bundle.plugin.settle

    expect(bundle.cards).to be_empty
  end

  it "doesn't hold the turn's end for the answer" do
    bundle = plugin
    release = Queue.new
    bundle.model_answers << lambda { |_request|
      release.pop
      REPLY
    }
    bundle.set(messages: conversation)
    bundle.fire(:after_turn, status: "completed", messages: conversation, answer: long)

    expect(bundle.cards).to be_empty
    release << true
    bundle.plugin.settle
    expect(bundle.cards.size).to eq(1)
  end

  it "doesn't write the conversation or steer" do
    bundle = plugin
    bundle.model_answers << REPLY
    end_turn(bundle)

    expect(bundle.steers).to be_empty
    expect(bundle.questions).to be_empty
    expect(bundle.ctx.messages.map { |message| message[:content] }).to eq(conversation.map { |message| message[:content] })
  end

  it "declares no command or tool" do
    bundle = plugin
    expect(bundle.bundle_commands).to be_empty
  end
end
