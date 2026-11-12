# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

# The compat corpus's wire samples (spec/compat/<version>/wire/): what a
# session's worker answers its clients, recorded at release time from a real
# Engine and Bridge in this process (a scripted kernel, no model, no
# plugins), read over the Bridge's real HTTP with its secret
# (WorkerLink.client), so the next release's readers (chi web's show, the
# attached terminal, a plugin's ctx.sessions) are checked against this
# one's replies (spec/compat/wire_readers_spec.rb). Not shipped; called by
# ReleaseTools.write_compat_wire! (docs/releasing.md).
#
# Each file is {route, status, body}: the body as the Bridge sent it, made
# deterministic (#normalise). The session file the worker saved is beside
# them (sessions/<SESSION_ID>.json), for the readers that load it too.
module CompatWire
  SESSION_ID = "compat-wire"
  # The idle sample's turn (a prompt, a read, the answer, a hook notice)
  # and the one held mid-turn with a prompt queued behind it.
  TURN_ID = "compat-turn"
  RUNNING_TURN_ID = "compat-turn-running"
  ENQUEUED_ID = "00000000-0000-4000-8000-000000000002"
  CLIENT_ID = "web:compat"
  PROMPT = "compatibility corpus"
  QUEUED_PROMPT = "queued behind the running turn"
  ANSWER = "It says compat."
  # The fixture's working directory, in place of the recording's temp one.
  CWD = "/compat-fixture"
  STAMP = "2026-01-01T00:00:00Z"
  EPOCH = "0c0ffee0"
  # A measured time's number (a key ending in _ms or _ms_sum, a running
  # generation's age), pinned.
  FIXED_NUMBER = 1000
  TIMING_KEY = /(?:_ms|_ms_sum)\z|\Aage\z/
  # The last turn's measured duration (last_turn.seconds, rounded to 0.1).
  # Only under last_turn: another `seconds` key is not a measurement.
  TIMING_PATH = { "last_turn" => "seconds" }.freeze
  # The system prompt's text (the tools' descriptions, the date: it changes
  # with every release and every day), as a recording keeps it.
  SYSTEM_PROMPT = "<system prompt>"
  ISO_TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\z/
  EVENT_ID = /\A(\d+)-\h+\z/
  # The idle files and the running one, each the route it answers.
  IDLE_ROUTES = { "state.json" => "state", "snapshot.json" => "snapshot", "tail.json" => "tail" }.freeze
  RUNNING_ROUTES = { "snapshot_running.json" => "snapshot" }.freeze
  SESSION_FILE = File.join("sessions", "#{SESSION_ID}.json").freeze
  EVENTS_FILE = "events.json"
  FILES = [*IDLE_ROUTES.keys, *RUNNING_ROUTES.keys, EVENTS_FILE, SESSION_FILE].freeze
  # How long the recording waits for the held turn to reach its step and to end (it raises then).
  WAIT_SECONDS = 15
  ENV_KEYS = %w[XDG_CONFIG_HOME XDG_STATE_HOME SAMAGOTCHI_RECAP_ENABLED SAMAGOTCHI_CACHE_WARMUP
                SAMAGOTCHI_UPDATE_NOTIFY SAMAGOTCHI_KEYCHAIN].freeze

  class Error < StandardError; end

  module_function

  # Record the samples into +dir+ (made; its FILES), as +version+ wrote them.
  # @return [Array<String>] the files
  def record!(dir, version:)
    load_chi
    Dir.mktmpdir("chi-compat-wire-") do |tmp|
      with_isolated_env(tmp) do
        replies = record_replies(tmp)
        roots = [tmp, File.realpath(tmp)].uniq
        replies.each do |name, reply|
          write_json(File.join(dir, name), normalise(reply, version: version, roots: roots))
        end
      end
    end
    FILES.map { |name| File.join(dir, name) }
  end

  # +value+ made deterministic: an ISO time is STAMP, an event id's epoch
  # EPOCH, a timing key's number (and last_turn.seconds) FIXED_NUMBER, the recording's temp folder
  # (+roots+) CWD, chi's version +version+ (chi_version, written_by), a
  # message list's system prompt SYSTEM_PROMPT; hashes' keys sorted (as
  # strings). Idempotent.
  def normalise(value, version:, roots: [], key: nil, parent: nil)
    case value
    when Hash
      value.keys.map(&:to_s).sort.to_h do |name|
        raw = value.key?(name) ? value[name] : value[name.to_sym]
        [name, normalise(raw, version: version, roots: roots, key: name, parent: key)]
      end
    when Array
      if key == "messages" && system_head?(value.first)
        value = [value.first.transform_keys(&:to_s).merge("content" => SYSTEM_PROMPT), *value.drop(1)]
      end
      value.map { |item| normalise(item, version: version, roots: roots, key: key, parent: parent) }
    when String then normalise_string(value, version: version, roots: roots, key: key)
    when Numeric then timing?(key, parent) ? FIXED_NUMBER : value
    else value
    end
  end

  def timing?(key, parent)
    TIMING_KEY.match?(key.to_s) || TIMING_PATH[parent] == key
  end

  # A message list's system prompt (its first message: a system one of no kind).
  def system_head?(message)
    return false unless message.is_a?(Hash)

    role = message["role"] || message[:role]
    kind = message["kind"] || message[:kind]
    role.to_s == "system" && kind.to_s.empty?
  end

  def normalise_string(text, version:, roots:, key:)
    return version if %w[chi_version written_by version].include?(key) && text == Samagotchi::VERSION
    return STAMP if ISO_TIME.match?(text)

    event_id = %w[event_id last_event_id].include?(key) && EVENT_ID.match(text)
    return "#{event_id[1]}-#{EPOCH}" if event_id

    roots.reduce(text) { |shown, root| shown.gsub(root, CWD) }
  end

  # The first JSON path at which +a+ and +b+ differ ("$.body.snapshot…"),
  # nil when they are equal.
  def first_difference(a, b, path = "$")
    return nil if a == b
    return path unless a.instance_of?(b.class)

    children = case a
               when Hash then (a.keys | b.keys).map { |name| [a[name], b[name], "#{path}.#{name}"] }
               when Array
                 return "#{path}[#{[a.size, b.size].min}]" unless a.size == b.size

                 a.each_index.map { |index| [a[index], b[index], "#{path}[#{index}]"] }
               else []
               end
    children.each do |left, right, at|
      found = first_difference(left, right, at)
      return found if found
    end
    path
  end

  def write_json(path, data)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#{JSON.pretty_generate(data)}\n")
  end

  def load_chi
    $LOAD_PATH.unshift(File.expand_path("../../lib", __dir__)) unless $LOAD_PATH.include?(File.expand_path("../../lib", __dir__))
    require "samagotchi/engine"
    require "samagotchi/bridge"
    require "samagotchi/session"
    require "samagotchi/worker_link"
    require "samagotchi/owner_lock"
    require "samagotchi/reminder_store"
    require "samagotchi/llm_context_forget"
    define_fakes
  end

  # A recording reads no user state: its own config and state homes, no
  # recap, no cache warm-up, no update notice, no keychain.
  def with_isolated_env(tmp)
    saved = ENV_KEYS.to_h { |name| [name, ENV.fetch(name, nil)] }
    ENV["XDG_CONFIG_HOME"] = File.join(tmp, "config")
    ENV["XDG_STATE_HOME"] = File.join(tmp, "state")
    ENV["SAMAGOTCHI_RECAP_ENABLED"] = "false"
    ENV["SAMAGOTCHI_CACHE_WARMUP"] = "off"
    ENV["SAMAGOTCHI_UPDATE_NOTIFY"] = "off"
    ENV["SAMAGOTCHI_KEYCHAIN"] = "off"
    FileUtils.mkdir_p(File.join(tmp, "config", "samagotchi"))
    File.write(File.join(tmp, "config", "samagotchi", "config.yml"), "default:\n  model: compat:model\n")
    yield
  ensure
    saved&.each { |name, value| value ? ENV[name] = value : ENV.delete(name) }
  end

  # The replies, by file name: the idle routes after one turn, then the
  # snapshot of a second turn held mid-turn with a prompt queued behind it,
  # the first turn's SSE replay from sequence 0, then the session file.
  def record_replies(tmp)
    state_dir = File.join(tmp, "sessions")
    FileUtils.mkdir_p(state_dir)
    session = Samagotchi::Session.new(id: SESSION_ID, mode: "assist", model_name: "compat:model", working_directory: tmp,
                                      created_at: STAMP, updated_at: STAMP, messages: [])
    session.save(state_dir: state_dir)
    session_dir = Samagotchi::Session.session_dir(SESSION_ID, state_dir: state_dir)
    client = FakeClient.new
    kernel = ScriptedKernel.new(client: client, services: Samagotchi::KernelLoop::Services.none(reminder_store: Samagotchi::ReminderStore.new))
    engine = Samagotchi::Engine.new(client: client, kernel: kernel, plugins: false, model_name: "compat:model")
    engine.session_state_dir = state_dir
    engine.session = session
    lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker", wait: 0) or raise Error, "the recording's owner lock is held"
    bridge = Samagotchi::Bridge.new(engine: engine, state_dir: state_dir, session_id: SESSION_ID).start
    begin
      link = Samagotchi::WorkerLink.client(SESSION_ID, session_dir: session_dir) or raise Error, "the recording's worker isn't live"
      replies = {}
      engine.run_turn(session, PROMPT, origin: { client_id: CLIENT_ID }, id: TURN_ID)
      IDLE_ROUTES.each { |name, route| replies[name] = reply(link, route) }
      replies[EVENTS_FILE] = record_events(link, engine.event_count)
      # Saved as its worker saves it after a turn.
      session.save(state_dir: state_dir)
      replies[SESSION_FILE] = JSON.parse(File.read(Samagotchi::Session.session_file(SESSION_ID, state_dir: state_dir)))

      # Held at its second step: the Bridge's observers have folded every
      # event before it (delivery is synchronous), so the snapshot has the
      # read and the working set; the queued prompt is in it once POST
      # turn answers (announced under the event lock before the reply).
      reached = kernel.hold!
      turn = Thread.new { engine.run_turn(session, "#{PROMPT} again", origin: { client_id: CLIENT_ID }, id: RUNNING_TURN_ID) }
      reached.pop(timeout: WAIT_SECONDS) or raise Error, "compat wire: the running turn never reached its second step"
      queued = link.post_turn(prompt: QUEUED_PROMPT, client_id: CLIENT_ID, enqueued_id: ENQUEUED_ID, delivery: "queue")
      raise Error, "the queued prompt was refused: #{queued.status} #{queued.body}" unless queued.status == 202

      RUNNING_ROUTES.each { |name, route| replies[name] = reply(link, route) }
      kernel.release!
      turn.join(WAIT_SECONDS) or raise Error, "the running turn didn't end"
      turn.value
      replies
    ensure
      kernel.release!
      bridge.stop
      engine.shutdown
      lock.release
    end
  end

  def reply(link, route)
    response = link.get_response(route)
    { "route" => route, "status" => response.status, "body" => JSON.parse(response.body) }
  end

  # The parsed events the page's openStream handlers receive from a replay
  # starting at seq 0. Stop at the event count captured after the turn.
  def record_events(link, count)
    opened = link.open_stream(last_event_id: "0")
    unless opened.is_a?(Samagotchi::BridgeClient::StreamOpen::Opened)
      raise Error, "compat wire: the event stream could not be opened"
    end

    events = []
    buffer = +""
    link.read_stream(opened, running: -> { events.size < count }) do |chunk|
      buffer << chunk
      while (separator = /\r?\n\r?\n/.match(buffer))
        frame = buffer.slice!(0, separator.begin(0))
        buffer.slice!(0, separator[0].length)
        lines = frame.split(/\r?\n/)
        type = lines.find { |line| line.start_with?("event: ") }&.delete_prefix("event: ")
        data = lines.filter_map { |line| line.delete_prefix("data: ") if line.start_with?("data: ") }.join("\n")
        next unless type && !data.empty?

        events << { "type" => type, "data" => JSON.parse(data) }
        break if events.size == count
      end
      break if events.size == count
    end
    raise Error, "compat wire: expected #{count} SSE events, received #{events.size}" unless events.size == count

    events
  end

  # The kernel's collaborators, defined once chi is loaded.
  def define_fakes
    return if const_defined?(:ScriptedKernel, false)

    # The client an Engine asks per turn (the window probe, /props): nothing.
    const_set(:FakeClient, Class.new do
      def invalidate_context_window! = nil
      def server_props(*, **) = nil
      def cached_server_props(*, **) = nil
      def slot_status(*, **) = nil
    end)
    const_set(:ScriptedKernel, Class.new(Samagotchi::KernelLoop) do
      # A turn as a model would run it: a step that reads README.md (a
      # hook's notice beside it), then the answer, each as KernelLoop
      # streams them. Held (#hold!) after the read until #release!.
      def run(messages, on_stream_event: nil, context: own_context, **)
        emit = on_stream_event || ->(_event) {}
        call = { id: "c1", name: "read", arguments: '{"path":"README.md"}' }
        conversation = messages + [{ role: "model", content: "Reading.", tool_calls: [call] },
                                   { role: "tool_response", content: "[read]\ncompat", tool_call_id: "c1", tool_ids: ["compat-t1"] }]
        self.llm_context_turn = Samagotchi::LLMContextForget::Turn.new(conversation: messages, context: nil, turn_id: context.id)
        emit.call(type: :generation_started, iteration: 1)
        emit.call(type: :generation_chunk, iteration: 1, content: "Reading.", text: "Reading.", thinking: "")
        emit.call(type: :generation_completed, iteration: 1)
        params = 'path="README.md"'
        emit.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "read", params: params, tool_id: "compat-t1",
                  title: "README.md")
        emit.call(type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", tool_id: "compat-t1",
                  output: "[read]\ncompat", output_truncated: false, duration_ms: 12,
                  activity: { tool: "read", status: "ok", params: params, action: "reading file", title: "README.md" })
        emit.call(type: :hook_notice, hook: "compat", text: "compatibility corpus")
        self.llm_context_turn = Samagotchi::LLMContextForget::Turn.new(conversation: conversation, context: nil, turn_id: context.id)
        emit.call(type: :generation_started, iteration: 2)
        if (gate = @gate)
          @reached.push(true)
          gate.pop
        end
        emit.call(type: :generation_chunk, iteration: 2, content: CompatWire::ANSWER, text: CompatWire::ANSWER, thinking: "")
        emit.call(type: :generation_completed, iteration: 2)
        Samagotchi::LLM::ModelResult.new(text: CompatWire::ANSWER,
                                         conversation: conversation + [{ role: "model", content: CompatWire::ANSWER }])
      end

      # The next turn waits at its second step for #release!.
      # @return [Queue] pushed once it waits there
      def hold!
        @gate = Queue.new
        @reached = Queue.new
      end

      def release!
        @gate&.push(true)
        @gate = nil
      end
    end)
  end
end
