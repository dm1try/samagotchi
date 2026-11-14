# frozen_string_literal: true

require "spec_helper"
require "samagotchi/worker_link"
require "tmpdir"
require "samagotchi/plugin/context"
require "samagotchi/session_manager"
require "samagotchi/bridge/turn_drawings"

# ctx.sessions (docs/plugins.md, Sessions): fork, send and read.
RSpec.describe Samagotchi::Plugin::Sessions do
  let(:tmpdir) { Dir.mktmpdir }
  let(:parent) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir).tap do |s|
      s.messages = [{ role: "user", content: "hello" }, { role: "model", content: "hi" }]
      s.save(state_dir: tmpdir)
    end
  end
  let(:session_id) { parent.id }
  let(:host) do
    Samagotchi::Plugin::Host.new(session_id: -> { session_id }, cwd: -> { tmpdir }, model_name: -> { "gemma4" },
                                 state_dir: -> { tmpdir })
  end
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: host) }
  let(:sessions) { ctx.sessions }

  after { FileUtils.rm_rf(tmpdir) }

  before { allow(Process).to receive(:spawn).and_return(12_345) }

  it "has no #review: chi starts no review sessions" do
    expect(sessions).not_to respond_to(:review)
  end

  describe "#fork" do
    it "starts an idle child of this session from the messages (frozen ones too)" do
      parent.preloaded_memory_names = ["a"]
      parent.muted_memory_names = ["b"]
      parent.save(state_dir: tmpdir)
      host.setup = -> { Samagotchi::SessionSetup.of(parent, forked: true) }
      seed = [{ role: "user", content: "hello" }.freeze, { role: "model", content: "hi" }.freeze,
              { role: "user", content: "q" }, { role: "model", content: "a" }].freeze

      id = sessions.fork(messages: seed, title: "q")

      child = Samagotchi::Session.load(id, state_dir: tmpdir)
      expect(child).to have_attributes(parent_id: parent.id, first_preview: "q", status: "idle",
                                       model_name: "gemma4", working_directory: tmpdir, toolkit_origin: "inherited",
                                       preloaded_memory_names: ["a"], muted_memory_names: ["b"])
      expect(child.messages.map { |m| m[:content] }).to eq(%w[hello hi q a])
      expect(Samagotchi::SessionManager.children_of(parent.id, state_dir: tmpdir).map(&:id)).to eq([id])
    end

    it "copies this session's own llm_context values, thinking and reasoning_history levels, appended prompt files, " \
       "toolkit and bundle settings to the child" do
      override = Samagotchi::LLMContextOverride.new(strategy: [:stale], apply: :turn_end)
      host.setup = lambda {
        Samagotchi::SessionSetup.new(llm_context: override, thinking: :high, reasoning_history: :all,
                                     appended_prompt_files: ["/r/extra.md"], toolkit: Samagotchi::Toolkit.new(name: "lean"),
                                     toolkit_origin: "inherited",
                                     settings: Samagotchi::SessionConfig::Settings.new(core: { "recap.enabled" => false }, bundles: { "cost-cap" => { "cap" => 0.5 } }))
      }

      child = Samagotchi::Session.load(sessions.fork(messages: []), state_dir: tmpdir)

      expect(child).to have_attributes(llm_context: override, thinking: :high, reasoning_history: :all,
                                       appended_prompt_files: ["/r/extra.md"], toolkit: Samagotchi::Toolkit.new(name: "lean"),
                                       toolkit_origin: "inherited",
                                       settings: Samagotchi::SessionConfig::Settings.new(core: { "recap.enabled" => false }, bundles: { "cost-cap" => { "cap" => 0.5 } }))
    end

    it "takes this session's movable attached context, as the seed last had it, with a note" do
      state = File.join(tmpdir, "state", "sessions")
      host.state_dir = -> { state }
      parent.save(state_dir: state)
      own = Samagotchi::ContextSources.session_location(parent.id, state_dir: state)
      own.add(Samagotchi::ContextSources::Source.new(name: "pr-1", cmd: "x", every_seconds: nil, why: nil, hint: nil,
                                                     scope: nil, added_by: "cli", created_at: nil))
      snap = own.record_text("pr-1", Samagotchi::ContextSources::Fetched.new(text: "t", summary: nil, wake: false, hint: nil))
      seed = [{ role: "system", kind: "note", context_source: "pr-1", note_id: "ctx-pr-1-1-#{snap.revision[0, 12]}",
                content: "[CONTEXT NOTE]" }, { role: "user", content: "q" }]

      id = sessions.fork(messages: seed)

      forked = Samagotchi::ContextSources.session_location(id, state_dir: state)
      expect(forked.sources.map(&:name)).to eq(["pr-1"])
      expect(forked.subscription("pr-1")).to have_attributes(seen: snap.revision, seen_serial: 1)
      notes = Samagotchi::SessionInbox.find_new_note_files(Samagotchi::Session.session_dir(id, state_dir: state))
                                      .map { |f| Samagotchi::SessionInbox.read_note(f)[:text] }
      expect(notes).to eq(["Context moved with this session: pr-1."])
    end

    it "carries the parent's turn drawings its seed keeps as they were, and none of a turn it changed" do
      drawings = Samagotchi::Bridge::TurnDrawings
      head = { role: "system", content: "You are chi." }
      parent.messages = [head, { role: "user", content: "hello", turn_id: "tp" }, { role: "model", content: "hi" },
                         { role: "user", content: "more", turn_id: "tq" }, { role: "model", content: "yes" }]
      parent.save(state_dir: tmpdir)
      line = lambda do |id, from, to|
        drawings::Line.new(v: 1, turn_id: id, kind: "completed", from: from, to: to,
                           from_digest: drawings.digest(parent.messages[from]), to_digest: drawings.digest(parent.messages[to - 1]),
                           drawing: { "prompt" => "x", "turn_id" => id, "parts" => [] }, end: { "type" => "turn_completed", "turn_id" => id })
      end
      parent_dir = Samagotchi::Session.session_dir(parent.id, state_dir: tmpdir)
      FileUtils.mkdir_p(parent_dir)
      File.write(File.join(parent_dir, drawings::FILE), [line.call("tp", 1, 3), line.call("tq", 3, 5)].map { |l| "#{JSON.generate(l.to_h)}\n" }.join)
      # A plugin's seed (ctx.messages, no system head): the first turn kept, the second's answer changed.
      seed = parent.messages[1, 3] + [{ role: "model", content: "no" }, { role: "user", content: "q" }, { role: "model", content: "a" }]

      id = sessions.fork(messages: seed)

      carried = drawings.read(Samagotchi::Session.session_dir(id, state_dir: tmpdir))
      expect(carried.map { |l| [l.turn_id, l.from, l.to] }).to eq([["tp", 1, 3]])
      # Once the child's first turn puts its head back, the carried line draws that turn; the others are made.
      child = [head] + Samagotchi::Session.load(id, state_dir: tmpdir).messages
      covered = drawings.cover(carried, child)
      expect(covered.first).to eq(carried.first)
      expect(covered[1]).to have_attributes(turn_id: "tq", from: 3, to: 5)
      expect(covered[2].turn_id).to start_with("m5-")
    end

    it "carries them for a seed that keeps the system head too" do
      drawings = Samagotchi::Bridge::TurnDrawings
      parent.messages = [{ role: "system", content: "You are chi." }, { role: "user", content: "hello", turn_id: "tp" }, { role: "model", content: "hi" }]
      parent.save(state_dir: tmpdir)
      kept = drawings::Line.new(v: 1, turn_id: "tp", kind: "completed", from: 1, to: 3, from_digest: drawings.digest(parent.messages[1]),
                                to_digest: drawings.digest(parent.messages[2]), drawing: { "parts" => [] }, end: { "type" => "turn_completed" })
      parent_dir = Samagotchi::Session.session_dir(parent.id, state_dir: tmpdir)
      FileUtils.mkdir_p(parent_dir)
      File.write(File.join(parent_dir, drawings::FILE), "#{JSON.generate(kept.to_h)}\n")

      id = sessions.fork(messages: parent.messages + [{ role: "user", content: "q" }])

      expect(drawings.read(Samagotchi::Session.session_dir(id, state_dir: tmpdir)).map(&:turn_id)).to eq(["tp"])
    end

    it "starts the fork without drawings when the parent has none" do
      id = sessions.fork(messages: [{ role: "user", content: "q" }])
      expect(File).not_to exist(File.join(Samagotchi::Session.session_dir(id, state_dir: tmpdir), Samagotchi::Bridge::TurnDrawings::FILE))
    end

    # A plugin's first prompt is the plugin's, as its send is (CommandIntake):
    # its ! line is refused and its /word line is text, in the child too.
    it "gives the child's first prompt the plugin as its sender, none to an idle fork" do
      allow(Samagotchi::Tools::Delegate).to receive(:running_children).and_return([])
      prompted = Samagotchi::Session.load(sessions.fork(messages: [], prompt: "!touch x"), state_dir: tmpdir)
      idle = Samagotchi::Session.load(sessions.fork(messages: []), state_dir: tmpdir)

      expect(prompted.first_turn_client_id).to eq(Samagotchi::ClientId::PLUGIN)
      expect(idle.first_turn_client_id).to be_nil
    end

    it "runs a prompt as the child's first turn, within session.max_children" do
      allow(Samagotchi::Tools::Delegate).to receive(:max_children).and_return(1)
      allow(Samagotchi::Tools::Delegate).to receive(:running_children).and_return([])
      id = sessions.fork(messages: [], prompt: "go on")
      expect(Samagotchi::Session.load(id, state_dir: tmpdir)).to have_attributes(status: "running", last_prompt: "go on")

      allow(Samagotchi::Tools::Delegate).to receive(:running_children).and_return([Samagotchi::SessionRow.from_summary_h({ id: id })])
      expect { sessions.fork(messages: [], prompt: "more") }
        .to raise_error(described_class::Error, /1 child sessions of this session are running \(the most is 1/)
      # An idle fork doesn't count.
      expect(sessions.fork(messages: [])).to match(/\A[\w-]{36}\z/)
    end

    it "is what the child's ctx.fork? says (a delegate child, the parent and no session are not forks)" do
      ctx_of = lambda do |id|
        Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {},
                                        host: Samagotchi::Plugin::Host.new(session_id: -> { id }, cwd: -> { tmpdir },
                                                                           state_dir: -> { tmpdir }))
      end
      delegate = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir,
                                                 parent_id: parent.id, delegate: true).tap { |s| s.save(state_dir: tmpdir) }

      expect(ctx_of.call(sessions.fork(messages: [])).fork?).to be(true)
      expect([ctx_of.call(delegate.id).fork?, ctx_of.call(parent.id).fork?, ctx_of.call(nil).fork?, ctx_of.call("nope").fork?])
        .to eq([false, false, false, false])
      expect(ctx_of.call(delegate.id).delegate?).to be(true)
    end

    it "raises Error with chi's reason when the child's toolkit or model is refused" do
      [[Samagotchi::Toolkit::Refused, "toolkit.kits.typo: groups: must be a name or a list"],
       [Samagotchi::ModelProfile::MissingModel, "model gone is not in the config"]].each do |klass, reason|
        allow(Samagotchi::SessionManager).to receive(:spawn_session).and_raise(klass, reason)
        expect { sessions.fork(messages: []) }.to raise_error(described_class::Error, reason)
      end
    end

    context "from a scratch session" do
      let(:host) do
        Samagotchi::Plugin::Host.new(session_id: -> { session_id }, cwd: -> { tmpdir }, model_name: -> { "gemma4" },
                                     state_dir: -> { tmpdir }, scratch: -> { true })
      end

      it "raises: the child would outlive it" do
        expect { sessions.fork(messages: []) }.to raise_error(described_class::Error, /scratch session starts no other sessions/)
        expect(Samagotchi::SessionManager.children_of(parent.id, state_dir: tmpdir)).to be_empty
      end
    end

    context "without a session yet" do
      let(:session_id) { nil }

      it "raises" do
        expect { sessions.fork(messages: []) }.to raise_error(described_class::Error, /no id yet/)
      end
    end
  end

  describe "#send" do
    it "delivers a turn to the session, by id or prefix" do
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge))

      expect(sessions.send(parent.id[0, 8], "do this")).to eq(parent.id)
      expect(Samagotchi::SessionManager).to have_received(:deliver_turn)
        .with(parent.id, prompt: "do this", client_id: "plugin", state_dir: tmpdir, delivery: nil)
    end

    it "queues it for after the running turn with delivery: :queue; :next_step is the default" do
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge))

      sessions.send(parent.id, "later", delivery: :queue)
      expect(Samagotchi::SessionManager).to have_received(:deliver_turn)
        .with(parent.id, prompt: "later", client_id: "plugin", state_dir: tmpdir, delivery: "queue")
      sessions.send(parent.id, "now", delivery: "next_step")
      expect(Samagotchi::SessionManager).to have_received(:deliver_turn)
        .with(parent.id, prompt: "now", client_id: "plugin", state_dir: tmpdir, delivery: nil)
    end

    it "raises for :cut (plugins never cut) and an unknown delivery, before anything is sent" do
      allow(Samagotchi::SessionManager).to receive(:deliver_turn)

      expect { sessions.send(parent.id, "x", delivery: :cut) }.to raise_error(described_class::Error, /plugins never cut/)
      expect { sessions.send(parent.id, "x", delivery: :soon) }.to raise_error(described_class::Error, /:next_step or :queue/)
      expect(Samagotchi::SessionManager).not_to have_received(:deliver_turn)
    end

    it "raises with the worker's reason when it refuses a queue (older than queueing)" do
      allow(Samagotchi::SessionManager).to receive(:deliver_turn)
        .and_return(Samagotchi::SessionManager::DeliverResult.new(status: :refused, code: 409, ack: Samagotchi::Delivery::QUEUE_UNAVAILABLE))

      expect { sessions.send(parent.id, "x", delivery: :queue) }
        .to raise_error(described_class::Error, /refused the message \(delivery_unavailable: this session's worker predates/)
    end

    # Pick 1 (R3): a plugin is no person; a stop and an archive are the owner's.
    it "raises, starting nothing, for a session its owner stopped or archived" do
      allow(Samagotchi::SessionManager).to receive(:resume_session)
      Samagotchi::Session.mark_stopped(parent.id, state_dir: tmpdir)

      expect { sessions.send(parent.id, "x") }
        .to raise_error(described_class::Error, /refused the message \(session_stopped: the session is stopped/)
      Samagotchi::Session.clear_stopped(parent.id, state_dir: tmpdir)
      Samagotchi::ArchiveStore.archive(parent.id, state_dir: tmpdir)
      expect { sessions.send(parent.id, "x") }
        .to raise_error(described_class::Error, /refused the message \(session_archived: the session is archived/)
      expect(Samagotchi::Session.stopped_marker?(parent.id, state_dir: tmpdir)).to be(false)
      expect(Samagotchi::SessionManager).not_to have_received(:resume_session)
    end

    it "raises when the session didn't take it, or there is none" do
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(Samagotchi::SessionManager::DeliverResult.new(status: :timeout, ack: nil))

      expect { sessions.send(parent.id, "x") }.to raise_error(described_class::Error, /did not answer in time/)
      expect { sessions.send("nope", "x") }.to raise_error(described_class::Error, /no session nope/)
    end
  end

  describe "#read" do
    it "reads a saved session without a worker" do
      expect(sessions.read(parent.id)).to eq(
        id: parent.id, title: "hello", status: "idle", parent_id: nil, running: false,
        messages: [{ role: "user", content: "hello" }, { role: "model", content: "hi" }]
      )
    end

    it "titles it by its own title when it has one" do
      parent.title = "Coordinator"
      parent.save(state_dir: tmpdir)

      expect(sessions.read(parent.id)).to include(title: "Coordinator")
    end

    it "reads a live worker's snapshot, with its running turn so far" do
      client = instance_double(Samagotchi::BridgeClient)
      allow(Samagotchi::WorkerLink).to receive(:client).and_return(client)
      # GET snapshot's reply: the turn snapshot beside the session state (Bridge#snapshot_frame).
      allow(client).to receive(:get_json).with("snapshot").and_return(
        "snapshot" => {
          "messages" => [{ "role" => "system", "content" => "prompt" }, { "role" => "user", "content" => "hello" }],
          "current_turn" => { "prompt" => "now", "parts" => [{ "kind" => "text", "iteration" => 1, "text" => "Wor" }] }
        },
        "session_state_snapshot" => { "status" => "running" }
      )

      expect(sessions.read(parent.id)).to include(
        running: true,
        messages: [{ role: "user", content: "hello" }, { role: "user", content: "now" }, { role: "model", content: "Wor" }]
      )
    end
  end

  describe "#children" do
    def child_of(parent_id, delegate: false, prompt: "work")
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir,
                                      parent_id: parent_id, delegate: delegate, now: next_stamp).tap do |s|
        s.last_prompt = prompt
        s.save(state_dir: tmpdir, now: next_stamp)
      end
    end

    it "lists this session's children, delegates and forks, as frozen hashes; archived ones only with all:" do
      delegate = child_of(parent.id, delegate: true, prompt: "count the specs")
      fork = child_of(parent.id, prompt: "btw")
      archived = child_of(parent.id, delegate: true)
      Samagotchi::ArchiveStore.archive(archived.id, state_dir: tmpdir)
      child_of(nil, prompt: "a stranger")

      rows = sessions.children
      expect(rows.map { |r| r.values_at(:id, :delegate, :title, :state) })
        .to eq([[fork.id, false, "btw", "idle"], [delegate.id, true, "count the specs", "idle"]])
      expect(rows).to all(be_frozen)
      expect(rows.first.keys).to include(:short_id, :branch, :last_reply, :reported, :cwd, :waiting)
      expect(sessions.children(all: true).map { |r| r[:id] }).to include(archived.id)
    end

    context "without a session yet" do
      let(:session_id) { nil }

      it "is empty" do
        expect(sessions.children).to eq([])
      end
    end
  end

  describe "#stop" do
    let(:child) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir,
                                      parent_id: parent.id, delegate: true).tap { |s| s.save(state_dir: tmpdir) }
    end

    it "stops one of this session's own children by id, waiting a little for its worker" do
      allow(Samagotchi::SessionManager).to receive(:stop_session).and_return(true)

      expect(sessions.stop(child.id[0, 8])).to eq(child.id)
      expect(Samagotchi::SessionManager).to have_received(:stop_session).with(child.id, state_dir: tmpdir, wait: 2)
    end

    it "refuses a session that isn't its child, an unknown one, a child whose file is corrupt, and one a one-shot owns" do
      stranger = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
      stranger.save(state_dir: tmpdir)
      allow(Samagotchi::SessionManager).to receive(:stop_session).and_call_original

      expect { sessions.stop(stranger.id) }.to raise_error(described_class::Error, "session #{stranger.id[0, 8]} is not a child of this session")
      expect { sessions.stop(parent.id) }.to raise_error(described_class::Error, /is not a child of this session/)
      expect { sessions.stop("nope") }.to raise_error(described_class::Error, /nope/)
      expect(Samagotchi::SessionManager).not_to have_received(:stop_session)

      corrupt = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir, parent_id: parent.id)
      corrupt.save(state_dir: tmpdir)
      File.write(File.join(tmpdir, "#{corrupt.id}.json"), "{not json")
      expect { sessions.stop(corrupt.id) }.to raise_error(described_class::Error, /Session file corrupted \(#{corrupt.id}\)/)
      expect(Samagotchi::SessionManager).not_to have_received(:stop_session)

      allow(Samagotchi::SessionManager).to receive(:stop_session).and_raise(Samagotchi::SessionManager::OwnedByTUI, child.id)
      expect { sessions.stop(child.id) }.to raise_error(described_class::Error, "session #{child.id[0, 8]} is in use by a one-turn chi --non-interactive run or an older chi's terminal; let it finish")
    end
  end
end

RSpec.describe Samagotchi::Plugin::Context, "sessions:" do
  let(:host) { Samagotchi::Plugin::Host.new(session_id: -> { "s1" }, cwd: -> { Dir.pwd }) }

  it "returns the given sessions object instead of building one over the host" do
    given = Object.new
    ctx = described_class.new(bundle: "b", label: "l", settings: {}, host: host, sessions: given)
    expect(ctx.sessions).to equal(given)
  end

  it "builds a Sessions over the host without one, once" do
    ctx = described_class.new(bundle: "b", label: "l", settings: {}, host: host)
    expect(ctx.sessions).to be_a(Samagotchi::Plugin::Sessions)
    expect(ctx.sessions).to equal(ctx.sessions)
  end
end
