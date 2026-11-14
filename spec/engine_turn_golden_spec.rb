# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "yaml"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/grants"
require "samagotchi/participants"
require_relative "support/fake_provider_server"
require_relative "support/outdated_grants"

# The goldens' fixed inputs and masks (a module: constants in a describe
# block would be top-level ones).
module TurnGolden
  SESSION_ID = "00000000-0000-4000-8000-00000000c0de"
  TURN_ID = "00000000-0000-4000-8000-00000000beef"

  # The request headers a golden leaves out: chi's version, the server's
  # port, the body's length (its paths differ per machine) and Net::HTTP's
  # own. Every other header is pinned.
  UNPINNED_HEADERS = %w[user-agent host content-length accept-encoding connection].freeze

  # Each wire's model, the model a before_turn hook switches to, the path
  # its server answers and the first model's temperature.
  WIRES = {
    "native" => { model: "box:Qwen3.6", other: "box:Qwen3.6-alt", path: "/completion", temperature: 0.3 },
    "openai" => { model: "oai:chat-a", other: "oai:chat-b", path: "/v1/chat/completions", temperature: 0.2 },
    "anthropic" => { model: "ant:claude-a", other: "ant:claude-b", path: "/v1/messages", temperature: 0.2 }
  }.freeze

  # Keys whose values are the clock's or the machine's: a file's mtime,
  # a wait's milliseconds, a tool call's duration.
  CLOCK_KEYS = %i[mtime_ns waited_ms duration_ms].freeze

  # The context-status estimates count the prompt's characters, paths
  # included: they differ per machine, and so may their bucket.
  ESTIMATE = "<estimate>"

  # A string, array or object at least this long (as JSON) that the golden
  # showed before is named instead (the system prompt and the tools in each
  # request): "<as in request 2 $.tools>".
  SHOWN_ONCE = 1000
end

# Byte goldens of whole Engine#run_turn turns: a real Engine (its own
# KernelLoop, ChatLoop, ToolRunner, Gate and GuardrailWiring, nothing
# injected) over a FakeProviderServer, on the three wires: native
# (llama.cpp /completion, a Qwen 3.6 profile from /props, Qwen tool calls),
# `api: openai` and `api: anthropic`. Each golden holds, in order:
# - every request the server got: method, path, the headers (not
#   user-agent, host, content-length, Net::HTTP's), the body pretty-printed in its
#   own key order (each body is checked to be JSON.generate's bytes first,
#   so the pretty form pins them); the native prompt is shown raw below its
#   body;
# - the events the turn's on_event got: keys sorted, symbols as ":name";
#   the context-status estimates (they count the prompt, whose paths differ
#   per machine) and the clock's values (mtimes, waits) masked;
# - each before_tool_call hook's payload (call, params, context, targets);
# - each question the user was asked (the approval card);
# - the session's messages after the turn.
# Paths are <TMP> and <HOME>, the port <PORT>, uuids <UUID-n> by first
# sight; the session and turn ids are fixed. A long value shown before is
# named ("<as in request 2 $.tools>"), and a native prompt that extends the
# last one shows what it adds.
#
# Scenarios: a turn of two tool iterations (a muted memory_read and a read,
# then a write a config rule asks about, allowed once through the question
# flow, then the answer) per wire; a before_turn hook switching the model
# per wire (the request names the new model; its sampling and thinking are
# the old model's: #turn_settings runs before the hooks); and an older
# chi's read-only participant's turn on the openai wire (its calls refused
# by Guardrails::ParticipantRefusal). System 1, the toolkit suggestion, the
# context judge, the recap and the turn-end warm-up are off by config, so
# the order is the turn's own.
#
# The arch P3 refactors keep these byte-identical. After an intended change:
#   UPDATE_PROMPTS=1 bundle exec rspec spec/engine_turn_golden_spec.rb
#   git diff spec/fixtures/turn_goldens/
# A failing run writes what it got to tmp/turn_goldens/<golden>.actual and
# names the diff to run.
RSpec.describe "Engine turn goldens" do
  include OutdatedGrants

  let(:tmp) { File.realpath(Dir.mktmpdir("turn-golden")) }
  let(:project) { File.join(tmp, "project") }
  let(:state_dir) { File.join(tmp, "state", "samagotchi", "sessions") }
  let(:server) { FakeProviderServer.start }
  let(:events) { [] }
  let(:hook_payloads) { [] }
  let(:asked) { [] }

  around do |example|
    FakeProviderServer.without_webmock do
      FileUtils.mkdir_p(File.join(tmp, "project"))
      with_config_home(File.join(tmp, "config")) do
        with_env("XDG_STATE_HOME" => File.join(tmp, "state")) do
          Dir.chdir(File.join(tmp, "project")) { example.run }
        end
      end
    end
  ensure
    server.stop
    FileUtils.rm_rf(tmp)
  end

  before do
    File.write(File.join(tmp, "config", "samagotchi", "config.yml"), YAML.dump(
      "default" => { "model" => "box:Qwen3.6" },
      "hosts" => {
        "box" => { "host" => "127.0.0.1", "port" => server.port },
        "oai" => { "host" => "127.0.0.1", "port" => server.port, "api" => "openai", "remote" => true },
        "ant" => { "url" => server.root_url, "api" => "anthropic", "remote" => true }
      },
      "models" => {
        "Qwen3.6" => { "sampling" => { "temperature" => 0.3 }, "thinking" => "off" },
        "Qwen3.6-alt" => { "sampling" => { "temperature" => 0.9, "top_k" => 40 }, "thinking" => "high" },
        "chat-a" => { "sampling" => { "temperature" => 0.2, "top_k" => 20 }, "thinking" => "off" },
        "chat-b" => { "sampling" => { "temperature" => 0.8 }, "thinking" => "high" },
        "claude-a" => { "sampling" => { "temperature" => 0.2 }, "thinking" => "off" },
        "claude-b" => { "sampling" => { "temperature" => 0.8 }, "thinking" => "high" }
      },
      "guardrails" => {
        "system_one" => { "mode" => "off" },
        "rules" => [{ "id" => "golden-ask", "tool" => "write", "path" => "**/asked.txt", "verdict" => "ask",
                      "reason" => "the golden asks" }]
      },
      "toolkit" => { "suggest" => { "mode" => "off" } },
      "context" => { "candidates" => { "mode" => "off" } },
      "objectives" => { "system_one" => "off" },
      "recap" => { "enabled" => false },
      "cache" => { "warmup" => "off" }
    ))
    File.write(File.join(project, "notes.txt"), "golden notes\n")
    server.default("/props", json: { "chat_template" => "<|im_start|> <function=",
                                     "default_generation_settings" => { "n_ctx" => 32_768 } })
    server.default("/v1/models", json: { data: [] })
  end

  def fixture_dir = File.expand_path("fixtures/turn_goldens", __dir__)

  def expect_golden(name, actual)
    path = File.join(fixture_dir, name)
    if ENV["UPDATE_PROMPTS"] == "1"
      FileUtils.mkdir_p(fixture_dir)
      File.write(path, actual)
    end
    expect(File.exist?(path)).to be(true), "no golden #{path}: UPDATE_PROMPTS=1 bundle exec rspec #{__FILE__}"
    return if actual == File.read(path)

    # A whole-turn golden is long: write what this run got under tmp/
    # (git-ignored, kept after the run), so `diff` shows the change instead
    # of RSpec's truncated one.
    got = File.expand_path("../tmp/turn_goldens/#{name}.actual", __dir__)
    FileUtils.mkdir_p(File.dirname(got))
    File.write(got, actual)
    raise RSpec::Expectations::ExpectationNotMetError,
          "turn golden #{name} changed. See it: diff #{path} #{got}\n" \
          "Intended (not in an arch P3 phase): UPDATE_PROMPTS=1 bundle exec rspec #{__FILE__}"
  end

  # -- the engine and its session ---------------------------------------

  def engine_on(model, **options)
    engine = Samagotchi::Engine.new(host_registry: Samagotchi::HostRegistry.new, model_name: model, **options)
    engine.interface = :worker
    engine.session_state_dir = state_dir
    engine.set_question_sync_handler do |pending|
      asked << pending
      { selected: [pending[:options].first], selected_indices: [0] }
    end
    engine.register_hook(:before_tool_call) { |event| hook_payloads << event.slice(:iteration, :call, :params, :blocked, :block_reason, :context, :targets) }
    engine
  end

  def session_on(model)
    Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: project).tap do |session|
      session.id = TurnGolden::SESSION_ID
    end
  end

  def run(engine, session, prompt, **options)
    engine.store_model!(session)
    engine.session = session
    engine.run_turn(session, prompt, on_event: ->(event) { events << event }, id: TurnGolden::TURN_ID, **options)
  end

  # -- what each wire's server answers ----------------------------------

  # One model reply on +wire+: tool calls ([id, name, arguments]) or text.
  def reply(wire, calls: [], text: nil)
    case wire
    when "native" then native_reply(calls, text)
    when "openai" then openai_reply(calls, text)
    else anthropic_reply(calls, text)
    end
  end

  def native_reply(calls, text)
    content = text || calls.map do |(_id, name, args)|
      body = args.map { |key, value| "<parameter=#{key}>\n#{value}\n</parameter>\n" }.join
      "<tool_call>\n<function=#{name}>\n#{body}</function>\n</tool_call>"
    end.join("\n")
    ["data: #{JSON.generate(content: content, stop: false)}\n\n",
     "data: #{JSON.generate(content: "", stop: true, tokens_evaluated: 100, tokens_predicted: 10)}\n\n"]
  end

  # One chunk; with no delta, the usage chunk (no choices) that ends a stream.
  def openai_chunk(delta, finish = nil)
    chunk = { id: "chatcmpl-golden", object: "chat.completion.chunk", created: 1_790_000_000, model: "served-golden" }
    if delta
      chunk[:choices] = [{ index: 0, delta: delta, finish_reason: finish }]
    else
      chunk[:choices] = []
      chunk[:usage] = { prompt_tokens: 100, completion_tokens: 10, total_tokens: 110 }
    end
    "data: #{JSON.generate(chunk)}\n\n"
  end

  def openai_reply(calls, text)
    chunks = [openai_chunk({ role: "assistant", content: nil })]
    if text
      chunks << openai_chunk({ content: text })
      chunks << openai_chunk({}, "stop")
    else
      calls.each_with_index do |(id, name, args), index|
        chunks << openai_chunk({ tool_calls: [{ index: index, id: id, type: "function",
                                                function: { name: name, arguments: JSON.generate(args) } }] })
      end
      chunks << openai_chunk({}, "tool_calls")
    end
    chunks << openai_chunk(nil)
    chunks << "data: [DONE]\n\n"
  end

  def anthropic_event(event) = "event: #{event[:type]}\ndata: #{JSON.generate(event)}\n\n"

  def anthropic_reply(calls, text)
    blocks = if text
               [[{ type: "text", text: "" }, { type: "text_delta", text: text }]]
             else
               calls.map do |(id, name, args)|
                 [{ type: "tool_use", id: id, name: name, input: {} }, { type: "input_json_delta", partial_json: JSON.generate(args) }]
               end
             end
    events = [{ type: "message_start", message: { id: "msg_golden", type: "message", role: "assistant", model: "served-golden",
                                                  content: [], stop_reason: nil,
                                                  usage: { input_tokens: 100, output_tokens: 1 } } }]
    blocks.each_with_index do |(start, delta), index|
      events << { type: "content_block_start", index: index, content_block: start }
      events << { type: "content_block_delta", index: index, delta: delta }
      events << { type: "content_block_stop", index: index }
    end
    events << { type: "message_delta", delta: { stop_reason: text ? "end_turn" : "tool_use" }, usage: { output_tokens: 10 } }
    events << { type: "message_stop" }
    events.map { |event| anthropic_event(event) }.join
  end

  def enqueue(wire, **reply_options)
    server.enqueue(TurnGolden::WIRES.fetch(wire)[:path], sse: reply(wire, **reply_options))
  end

  # -- the golden's text --------------------------------------------------

  # Machine state out: the temp root, the home folder, the project memory
  # folder's hash of the temp path, the memory indexes' managed-line dates
  # (the day the example's bundles were installed: Date.today), the
  # server's port, uuids numbered by first sight.
  def scrub(text)
    text = text.gsub(tmp, "<TMP>").gsub(Dir.home, "<HOME>")
    text = text.gsub(%r{(memories/projects/project)_[0-9a-f]{8}}, '\1_<HASH>')
    text = text.gsub(/( · (?:system|project) · )\d{4}-\d{2}-\d{2}( · )/, '\1<DATE>\2')
    text = text.gsub("127.0.0.1:#{server.port}", "127.0.0.1:<PORT>")
    @uuids ||= {}
    text.gsub(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/) do |uuid|
      next uuid if [TurnGolden::SESSION_ID, TurnGolden::TURN_ID].include?(uuid)

      @uuids[uuid] ||= "<UUID-#{@uuids.size + 1}>"
    end
  end

  # A value as JSON: keys sorted, symbols ":name", objects by class.
  def plain(value)
    case value
    when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, item| [key.to_s, plain(item)] }
    when Array then value.map { |item| plain(item) }
    when Symbol then ":#{value}"
    when String, Integer, Float, true, false, nil then value
    when Samagotchi::LLM::ModelResult
      { "class" => "ModelResult", "text" => value.text, "canceled" => value.canceled, "exhausted" => value.exhausted }
    else "#<#{value.class.name}>"
    end
  end

  def masked(value)
    case value
    when Hash
      value.to_h do |key, item|
        [key, TurnGolden::CLOCK_KEYS.include?(key.to_sym) ? "<clock>" : masked(item)]
      end
    when Array then value.map { |item| masked(item) }
    else value
    end
  end

  def event_for_golden(event)
    event = masked(event)
    case event[:type]
    when :context_status then event.merge(status: TurnGolden::ESTIMATE, usage: TurnGolden::ESTIMATE, bucket: TurnGolden::ESTIMATE)
    when :turn_completed
      summary = event[:turn_summary]
      summary ? event.merge(turn_summary: summary.merge(context_status: TurnGolden::ESTIMATE)) : event
    else event
    end
  end

  # +value+ with what the golden showed before named; what it shows now is
  # remembered under +where+.
  def once(value, where)
    text = value.is_a?(String) ? value : JSON.generate(value)
    return value if text.length < TurnGolden::SHOWN_ONCE
    return "<as in #{@shown[text]}>" if @shown.key?(text)

    @shown[text] = where
    case value
    when Hash then value.to_h { |key, item| [key, once(item, "#{where}.#{key}")] }
    when Array then value.each_with_index.map { |item, index| once(item, "#{where}[#{index}]") }
    else value
    end
  end

  def request_text(request, label)
    headers = request.headers.except(*TurnGolden::UNPINNED_HEADERS).sort.to_h
    body = request.body.to_s.dup.force_encoding(Encoding::UTF_8)
    lines = ["#{request.method} #{request.path}#{"?#{request.query_string}" if request.query_string}",
             "headers: #{JSON.generate(headers)}"]
    return lines.join("\n") if body.empty?

    parsed = JSON.parse(body)
    # The pretty form pins the bytes only when they are JSON.generate's.
    expect(JSON.generate(parsed)).to eq(body), "#{request.path}'s body is not JSON.generate's bytes"
    prompt = parsed.delete("prompt") if parsed.is_a?(Hash) && parsed["prompt"].is_a?(String)
    lines << JSON.pretty_generate(once(parsed, "#{label} $"))
    lines << native_prompt_text(prompt, label) if prompt
    lines.join("\n")
  end

  # The native prompt as text; one that extends the last request's (the
  # history is append-only) shows only what it adds.
  def native_prompt_text(prompt, label)
    last = @last_prompt
    @last_prompt = [prompt, label]
    return "prompt (the body's \"prompt\", after its other keys):\n#{prompt}" unless last && prompt.start_with?(last[0])

    "prompt (the body's \"prompt\", after its other keys): #{last[1]}'s, then:\n#{prompt.delete_prefix(last[0])}"
  end

  def golden_text(session, result)
    @shown = {}
    @last_prompt = nil
    sections = []
    server.requests.each_with_index do |request, index|
      sections << "## request #{index + 1}\n#{request_text(request, "request #{index + 1}")}"
    end
    sections << "## events\n#{events.map { |event| JSON.generate(plain(event_for_golden(event))) }.join("\n")}"
    sections << "## before_tool_call\n#{hook_payloads.map { |payload| JSON.pretty_generate(plain(payload)) }.join("\n")}"
    sections << "## asked\n#{asked.map { |pending| JSON.pretty_generate(plain(pending.except(:created_at))) }.join("\n")}"
    sections << "## session messages\n#{JSON.pretty_generate(once(plain(masked(session.messages)), "the session $"))}"
    sections << "## result\n#{JSON.generate(plain(result))}"
    "#{scrub(sections.join("\n\n"))}\n"
  end

  # -- the scenarios ---------------------------------------------------------

  TurnGolden::WIRES.each_key do |wire|
    describe "on the #{wire} wire" do
      it "keeps a turn of two tool iterations: a muted memory_read and a read, then an asked write" do
        model = TurnGolden::WIRES[wire][:model]
        engine = engine_on(model, muted_memories: ["secret"])
        session = session_on(model)
        enqueue(wire, calls: [["call_m1", "memory_read", { "name" => "secret" }], ["call_r1", "read", { "path" => "notes.txt" }]])
        enqueue(wire, calls: [["call_w1", "write", { "path" => "asked.txt", "content" => "yes" }]])
        enqueue(wire, text: "Done.")

        result = run(engine, session, "Look at the notes, then write asked.txt.")

        expect(result.output).to eq("Done.")
        expect(File.read(File.join(project, "asked.txt"))).to eq("yes")
        expect(asked.size).to eq(1)
        expect_golden("#{wire}_tool_turn.txt", golden_text(session, result))
      end

      # The hook's switch reaches the request's model name, while the
      # sampling, thinking and vision are the old model's: #turn_settings
      # ran before the hooks (arch P3 r2 item 8).
      it "keeps a turn whose before_turn hook switches the model" do
        model, other = TurnGolden::WIRES[wire].values_at(:model, :other)
        engine = engine_on(model)
        session = session_on(model)
        engine.register_hook(:before_turn) { |_event| engine.switch_model!(other) }
        enqueue(wire, calls: [["call_r1", "read", { "path" => "notes.txt" }]])
        enqueue(wire, text: "Read it.")

        result = run(engine, session, "Read the notes.")

        expect(result.output).to eq("Read it.")
        bodies = server.requests.select { |request| request.path == TurnGolden::WIRES[wire][:path] }.map(&:json)
        expect(bodies.map { |body| [body["model"], body["temperature"]] })
          .to eq([[other.split(":").last, TurnGolden::WIRES[wire][:temperature]]] * 2)
        expect_golden("#{wire}_model_switch.txt", golden_text(session, result))
      end
    end
  end

  describe "an older chi's read-only participant's turn on the openai wire" do
    it "keeps the turn whose read and write the participant seat refuses" do
      model = TurnGolden::WIRES["openai"][:model]
      engine = engine_on(model)
      session = session_on(model)
      session.save(state_dir: state_dir)
      grants = Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: state_dir))
      grant = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Mallory", state_dir: state_dir).grant
      grant = make_outdated!(grants, grant, state_dir: state_dir)
      enqueue("openai", calls: [["call_r1", "read", { "path" => "notes.txt" }],
                                ["call_w1", "write", { "path" => "notes.txt", "content" => "pwned" }]])
      enqueue("openai", text: "Proposed a change.")

      result = run(engine, session, "Review the notes.", origin: { client_id: "participant:#{grant.id}", author: grant.author })

      expect(File.read(File.join(project, "notes.txt"))).to eq("golden notes\n")
      expect(asked).to eq([])
      text = golden_text(session, result).gsub(grant.id, "<GRANT>")
      expect(text).to include("denied by guardrail (rule participant-refused, core)")
      expect(text).not_to include("golden notes")
      expect_golden("openai_refused_participant.txt", text)
    end
  end
end
