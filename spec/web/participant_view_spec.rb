# frozen_string_literal: true

require "json"
require "samagotchi/web/participant_view"
require "samagotchi/web/participant_stream_filter"

RSpec.describe Samagotchi::Web::ParticipantView do
  let(:viewer) { described_class::Viewer.new(author: "p:p_1", cwd: "/home/o/proj", home: "/home/o", secrets: ["OWNERTOKEN123"]) }

  def shown(event) = described_class.event(JSON.parse(JSON.generate(event)), viewer)

  # Every event type chi emits (`type: :name` in lib) and every type the
  # web's stream handlers take is decided: a participant gets it
  # (EVENTS) or never does (DROPPED). A new type fails here until it is
  # named; unnamed, the filter drops it.
  describe "the event types" do
    NOT_EVENTS = %w[bool enum float integer string].freeze

    def emitted
      found = Set.new
      Dir[File.expand_path("../../lib/**/*.rb", __dir__)].each do |file|
        File.read(file).scan(/\btype: :([a-z_]+)/) { found << Regexp.last_match(1) }
      end
      handlers = File.read(File.expand_path("../../lib/samagotchi/web/public/stream_handlers.js", __dir__))
      handlers.scan(/^ {4}([a-z_]+): (?:async )?\(/) { found << Regexp.last_match(1) }
      found - NOT_EVENTS
    end

    it "names every emitted type as shown or dropped, never both" do
      known = described_class::EVENTS.keys + described_class::DROPPED
      expect(emitted.to_a.sort - known).to eq([])
      expect(described_class::EVENTS.keys & described_class::DROPPED).to eq([])
    end

    it "drops every DROPPED type and an unknown one, whatever they carry" do
      (described_class::DROPPED + ["brand_new_event"]).each do |type|
        expect(shown({ type: type, event_seq: 3, output: "secret", text: "x" })).to be_nil, type
      end
      expect(shown({ output: "no type" })).to be_nil
    end

    it "keeps only named fields of every shown type, whatever an event carries" do
      noisy = { event_seq: 7, turn_id: "t", iteration: 1, call_index: 0, text: "hi", tool: "read", output: "SECRET OUTPUT",
                params: "cat ~/.ssh/id_rsa", call: { name: "execute" }, thinking: "plan", pending_question: { q: 1 },
                session_id: "s", cost: 1.5, file: "/home/o/x", counts: { total_tokens: 1 }, origin: { client_id: "web:1" } }
      allowed = %w[type event_seq turn_id iteration call_index text tool path status prompt author author_name mine
                   automatic continue restarted]
      described_class::EVENTS.each_key do |type|
        out = shown(noisy.merge(type: type))
        next if out.nil?

        expect(out.keys - allowed).to eq([]), type
        expect(JSON.generate(out)).not_to include("SECRET", "ssh", "execute", "plan", "/home/o"), type
      end
    end
  end

  describe ".event" do
    it "shows a person's turn with its prompt and author, an automatic one without its text" do
      expect(shown({ type: :turn_started, prompt: "is step 3 safe?", turn_id: "t1", author: "p:p_1", author_name: "Alex",
                     origin: { client_id: "review:p_1", enqueued_id: "e1", author: "p:p_1" }, images: [{ file: "/x.png" }],
                     cut_after: 3, session_id: "s" }))
        .to eq("type" => "turn_started", "turn_id" => "t1", "prompt" => "is step 3 safe?", "author" => "p:p_1",
               "author_name" => "Alex", "mine" => true)
      expect(shown({ type: :turn_started, prompt: "owner's", origin: { client_id: "web:tab" } }))
        .to eq("type" => "turn_started", "prompt" => "owner's")
      expect(shown({ type: :turn_started, prompt: "check the deploy", origin: { client_id: "system:reminder" } }))
        .to eq("type" => "turn_started", "automatic" => true)
      expect(shown({ type: :turn_started, prompt: nil, continue: true, origin: { client_id: "web:t" } }))
        .to eq("type" => "turn_started", "continue" => true)
    end

    it "marks no turn as the owner's own when the owner looks through the participant view" do
      owner = described_class::Viewer.new(cwd: "/p")
      out = described_class.event({ "type" => "turn_started", "author" => "p:p_1", "origin" => { "client_id" => "review:p_1" } }, owner)
      expect(out).not_to have_key("mine")
    end

    it "keeps a chunk's visible text only, and drops a thinking-only chunk" do
      expect(shown({ type: :generation_chunk, text: "Yes", thinking: "hmm", tool_call: "x", counts: { total_tokens: 9 }, iteration: 2 }))
        .to eq("type" => "generation_chunk", "text" => "Yes", "iteration" => 2)
      expect(shown({ type: :generation_chunk, text: "", thinking: "hmm" })).to be_nil
    end

    it "shows a tool row as its name and a project path only" do
      expect(shown({ type: :tool_call_started, tool: "read", ref: { kind: "file", path: "/home/o/proj/docs/plan.md" },
                     title: "docs/plan.md", params: "docs/plan.md", view: { command: "x" }, iteration: 1, call_index: 0 }))
        .to eq("type" => "tool_call_started", "tool" => "read", "path" => "docs/plan.md", "iteration" => 1, "call_index" => 0)
      home = described_class::Viewer.new(cwd: "/home/o", home: "/home/o")
      expect(described_class.event({ "type" => "tool_call_started", "tool" => "read", "ref" => { "path" => "/home/o/.config/x.md" } }, home))
        .to eq("type" => "tool_call_started", "tool" => "read")
      expect(shown({ type: :tool_call_started, tool: "read", ref: { path: "/home/o/.ssh/id_rsa" } }))
        .to eq("type" => "tool_call_started", "tool" => "read")
      expect(shown({ type: :tool_call_started, tool: "execute", title: "curl -H 'Authorization: x'", params: "env" }))
        .to eq("type" => "tool_call_started", "tool" => "execute")
      expect(shown({ type: :tool_call_completed, output: "SECRET", activity: { status: "ok", action: "Read" }, iteration: 1,
                     call_index: 0, diff: {} }))
        .to eq("type" => "tool_call_completed", "status" => "ok", "iteration" => 1, "call_index" => 0)
    end

    it "shows a question, an approval or a Continue offer as its type alone" do
      expect(shown({ type: :question_requested, pending_question: { id: "q", question: "Allow execute: cat .env?" },
                     event_seq: 4 }))
        .to eq("type" => "question_requested", "event_seq" => 4)
      expect(shown({ type: :continue_offered, context: "step limit" })).to eq("type" => "continue_offered")
    end

    it "turns a snapshot or reset frame into a bare marker: the page re-reads its review data" do
      frame = { type: "snapshot", snapshot: { messages: [{ role: "user", content: "secret" }], cards: [1] },
                session_state_snapshot: { participants: [{ id: "p_2" }], status: "idle" } }
      expect(shown(frame)).to eq("type" => "snapshot")
      expect(shown(frame.merge(type: "reset"))).to eq("type" => "reset")
    end
  end

  describe ".messages" do
    it "keeps prompts and replies with their authors and tool rows; drops notes, steers, automatic input and markers" do
      list = [
        { role: "user", content: "look at docs/plan.md", turn_id: "t1" },
        { role: "assistant", content: "Reading.", parts: { thinking: "plan", tools: [
          { tool: "read", params: "docs/plan.md", output: "BODY", ref: { kind: "file", path: "/home/o/proj/docs/plan.md" } },
          { tool: "memory_read", params: "secrets", output: "MEMORY" }
        ] } },
        { role: "note", content: "deploy frozen", label: "slack" },
        { role: "steer", content: "status?", source: "check-in", step: 1 },
        { role: "user", content: "child report", merged: true, source: "delegate_report" },
        { role: "user", content: "also this", merged: true },
        { role: "empty_answer", content: "", retries: 1 },
        { role: "user", content: "is step 3 safe?", turn_id: "t2", author: "p:p_2", author_name: "Sam", images: [{ file: "/a.png" }] },
        { role: "assistant", content: "Yes.", html: "<p>raw</p>", display_refs: [{ kind: "file", path: "/etc/x" }] }
      ]
      expect(described_class.messages(list, viewer)).to eq([
        { "role" => "user", "content" => "look at docs/plan.md", "turn_id" => "t1" },
        { "role" => "assistant", "content" => "Reading.", "tools" => [{ "tool" => "read", "path" => "docs/plan.md" }, { "tool" => "memory_read" }] },
        { "role" => "user", "content" => "also this", "merged" => true },
        { "role" => "user", "content" => "is step 3 safe?", "turn_id" => "t2", "author" => "p:p_2", "author_name" => "Sam", "images" => 1 },
        { "role" => "assistant", "content" => "Yes." }
      ])
    end
  end

  describe ".current_turn" do
    it "shows the turn so far: its prompt, the reply's text, tool rows, and waiting for the owner" do
      turn = { "prompt" => "go", "origin" => { "client_id" => "web:1" }, "pending_question" => { "question" => "Allow?" },
               "parts" => [{ "kind" => "thinking", "text" => "secret plan" }, { "kind" => "text", "text" => "Looking" },
                           { "kind" => "tool", "tool" => "execute", "params" => "env", "status" => "running", "output" => "X" },
                           { "kind" => "input", "text" => "steer" }] }
      expect(described_class.current_turn(turn, viewer)).to eq(
        "prompt" => "go", "text" => "Looking", "tools" => [{ "tool" => "execute", "status" => "running" }], "waiting_for_owner" => true
      )
    end
  end

  describe ".visible_raw" do
    it "drops a cut-off thought or tool call and what came before a bare close; closed blocks stay for the rows" do
      vr = ->(text) { described_class.visible_raw(text) }
      expect(vr.call("Let me look.\n<tool_call>\n{\"name\":\"execute\",\"arguments\":{\"command\":\"cat SECRET\"}}")).to eq("Let me look.\n")
      expect(vr.call("ok <|tool_call>call:execute{command:cat SECRET}")).to eq("ok ")
      expect(vr.call("<think>SECRET plan")).to eq("")
      expect(vr.call("SECRET plan</think>\n\nThe answer.")).to eq("\n\nThe answer.")
      # Gemma's open thought channel runs to the end as one block (GEMMA_THOUGHT_RE): the display strips it.
      expect(Samagotchi::OutputFormatter.strip_markup(vr.call("ok <|channel>thought SECRET"))).to eq("ok")
      closed = "<think>a</think>Reading.<tool_call>{\"name\":\"read\"}</tool_call>"
      expect(vr.call(closed)).to eq(closed)
    end
  end

  describe "Redact" do
    it "takes the likeliest quoted secret shapes: env names, JSON keys, URL passwords, JWTs, Google and Stripe keys" do
      text = "OPENAI_API_KEY=abc123 DATABASE_PASSWORD=hunter2 AWS_SECRET_ACCESS_KEY=xyz {\"api_key\": \"k1\"} ?access_token=t1&x=1 " \
             "postgres://app:pa55@db/x eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT AIzaSyA1234567890abcdefghijklmnopqrstu rk_live_abcdefghijklmnop1234"
      out = described_class::Redact.text(text, viewer)
      %w[abc123 hunter2 xyz k1 t1 pa55 eyJzdWIi AIzaSy rk_live].each { |leak| expect(out).not_to include(leak), leak }
      expect(out).to include("postgres://app:[redacted]@db/x", "&x=1")
    end

    it "takes secret shapes, the owner's token, the session's folder and home out of every string" do
      text = "key sk-ant-abcdefghijklmnopqrstu ghp_abcdefghijklmnopqrstuvwxyz0123 AKIAABCDEFGHIJKLMNOP xoxb-1234567890-abc " \
             "chp_abcdefghijklmnopqrstuvwxyz Authorization: Bearer abc.def token=zzz OWNERTOKEN123 at /home/o/proj/a.rb in /home/o/proj, /home/o/notes " \
             "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY----- /home/oscar stays"
      out = described_class::Redact.text(text, viewer)
      expect(out).not_to include("sk-ant", "ghp_", "AKIA", "xoxb", "chp_", "abc.def", "zzz", "OWNERTOKEN", "MIIE", "/home/o/")
      expect(described_class::Redact.text("`API_KEY=sk-ant-abcdefghijklmnopqrstu` here", viewer)).to eq("`API_KEY=[redacted]` here")
      expect(out).to include("Authorization: Bearer [redacted]", "token=[redacted]", "at a.rb in ., ~/notes", "/home/oscar stays")
    end
  end
end

RSpec.describe Samagotchi::Web::ParticipantStreamFilter do
  subject(:filter) { described_class.new(viewer) }

  let(:viewer) { Samagotchi::Web::ParticipantView::Viewer.new(author: "p:p_1", cwd: "/p") }

  def frame(id, data) = "id: #{id}\r\nevent: #{data[:type]}\r\ndata: #{JSON.generate(data)}\r\n\r\n"

  it "rebuilds shown frames from the filtered event, drops the rest, passes pings, across any chunk split" do
    bytes = frame("1-ep", { type: "generation_chunk", text: "Hi\n", thinking: "secret" }) +
            frame("2-ep", { type: "tool_call_completed", output: "SECRET OUTPUT", iteration: 1, call_index: 0 }) +
            frame("3-ep", { type: "working_set_updated", items: [{ path: "/p/.env" }] }) +
            ": ping\r\n\r\n" +
            frame("4-ep", { type: "brand_new", text: "leak" })
    [1, 7, 4096].each do |size|
      out = bytes.chars.each_slice(size).map { |chars| filter.call(chars.join) }.join
      expect(out).to eq("id: 1-ep\r\nevent: generation_chunk\r\ndata: {\"type\":\"generation_chunk\",\"text\":\"Hi\\n\"}\r\n\r\n" \
                        "id: 2-ep\r\nevent: tool_call_completed\r\ndata: {\"type\":\"tool_call_completed\",\"iteration\":1,\"call_index\":0}\r\n\r\n" \
                        ": ping\r\n\r\n")
    end
  end

  it "drops a frame that isn't JSON, a forged id line and an oversized frame, and goes on after it" do
    expect(filter.call("data: not json\r\n\r\n")).to eq("")
    expect(filter.call("id: 1\r\nx\r\ndata: {\"type\":\"turn_completed\"}\r\n\r\n")).to eq(frame("1", { type: "turn_completed" }))
    expect(filter.call("id: <script>\r\ndata: {\"type\":\"turn_completed\"}\r\n\r\n")).not_to include("<script>")
    big = "data: {\"type\":\"generation_chunk\",\"text\":\"#{"x" * (described_class::MAX_FRAME_BYTES + 10)}"
    expect(filter.call(big)).to eq("")
    expect(filter.call("\"}\r\n\r\n#{frame("9", { type: "turn_completed" })}")).to eq(frame("9", { type: "turn_completed" }))
  end

  def texts(out) = out.scan(/^data: (.*)\r$/).flatten.map { |json| JSON.parse(json) }.select { |e| e["type"] == "generation_chunk" }.map { |e| e["text"] }.join

  it "sends the reply by whole lines, so a secret split over chunks is redacted as one" do
    out = ["token ghp_ABCDEFGHIJ", "KLMNOPQRSTUVWXYZ0123 done\n"].each_with_index
                                                                .map { |text, i| filter.call(frame(i.to_s, { type: "generation_chunk", text: text })) }.join
    expect(texts(out)).to eq("token [redacted] done\n")
  end

  # +text+ streamed in chunks of +size+ characters, then the turn's end: the reply text the participant got.
  def streamed(text, size)
    stream = described_class.new(viewer)
    out = text.chars.each_slice(size).map { |chars| stream.call(frame("1", { type: "generation_chunk", text: chars.join })) }.join
    texts(out + stream.call(frame("2", { type: "turn_completed" })))
  end

  {
    "password: hunter2supersecret" => "hunter2supersecret",
    "Authorization: Bearer abcDEF123valuexyz" => "abcDEF123valuexyz",
    "api_key = 'qwertyQWERTY0987'" => "qwertyQWERTY0987",
    "sk-ant-abcdefghijklmnopqrstuvwxyz0123" => "abcdefghijklmnop",
    "-----BEGIN RSA PRIVATE KEY-----\nKEYBODYKEYBODY\n-----END RSA PRIVATE KEY-----" => "KEYBODY"
  }.each do |secret, value|
    it "never splits #{secret.lines.first.strip} at a length cut, wherever the line puts it (400 or 1600 characters)" do
      filler = "lorem ipsum dolor sit amet " * 70
      (360..440).each do |at|
        [1, 7].each do |size|
          got = streamed("#{filler[0, at]} #{secret} and more words\n", size)
          expect(got).not_to include(value), "spaced, at #{at}, chunks of #{size}: #{got[-120..].inspect}"
          expect(got).to include("[redacted]")
        end
      end
      (1580..1620).step(4).each do |at|
        got = streamed("#{"x" * at}/#{secret} more\n", 5)
        expect(got).not_to include(value), "unbroken, at #{at}: #{got[-120..].inspect}"
      end
    end
  end

  it "withholds a private key block streamed over several chunks, from its BEGIN line to its END line" do
    parts = ["Here:\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blb", "nNzaC1rZXk\nAAAA\n-----END OPENSSH PRIVATE KEY-----\nafter\n"]
    out = parts.each_with_index.map { |text, i| filter.call(frame(i.to_s, { type: "generation_chunk", text: text })) }.join
    expect(texts(out)).to eq("Here:\n[redacted]\nafter\n")
  end

  it "withholds the next key block when its BEGIN shares a line with the last one's END" do
    parts = ["-----BEGIN EC PRIVATE KEY-----\nONE\n-----END EC PRIVATE KEY----- and ", "-----BEGIN EC PRIVATE KEY-----\nTWO\n",
             "-----END EC PRIVATE KEY-----\nafter\n"]
    out = parts.each_with_index.map { |text, i| filter.call(frame(i.to_s, { type: "generation_chunk", text: text })) }.join
    expect(texts(out)).to eq("[redacted]\nafter\n")
  end

  # L-P6: a key block the turn never closed is withheld to the turn's end
  # (fail closed), not to the stream's: the next turn's reply is sent.
  it "withholds an unclosed private key block to its turn's end, and sends the next turn's reply" do
    out = [frame("1", { type: "turn_started", prompt: "go" }),
           frame("2", { type: "generation_chunk", text: "Here:\n-----BEGIN RSA PRIVATE KEY-----\nMIIE\n" }),
           frame("3", { type: "generation_chunk", text: "still the key\n" }),
           frame("4", { type: "turn_completed" })].map { |bytes| filter.call(bytes) }.join
    expect(texts(out)).to eq("Here:\n[redacted]\n")
    out = [frame("5", { type: "turn_started", prompt: "again" }),
           frame("6", { type: "generation_chunk", text: "A new reply\n" }),
           frame("7", { type: "turn_completed" })].map { |bytes| filter.call(bytes) }.join
    expect(texts(out)).to eq("A new reply\n")
  end

  it "sends the held rest of a line before a tool row or the turn's end, and drops it at a restarted step" do
    out = filter.call(frame("1", { type: "generation_chunk", text: "Let me look", iteration: 1 })) +
          filter.call(frame("2", { type: "tool_call_started", tool: "read", iteration: 1, call_index: 0 }))
    expect(out.index("Let me look")).to be < out.index("tool_call_started")
    out = filter.call(frame("3", { type: "generation_chunk", text: "void", iteration: 2 })) +
          filter.call(frame("4", { type: "generation_retrying", restarted: true, iteration: 2 })) +
          filter.call(frame("5", { type: "generation_chunk", text: "Done", iteration: 2 })) +
          filter.call(frame("6", { type: "turn_completed" }))
    expect(texts(out)).to eq("Done")
    expect(out.index("Done")).to be < out.index("turn_completed")
  end
end
