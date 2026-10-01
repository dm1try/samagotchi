# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "stringio"

require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/engine"
require "samagotchi/bridge"
require "samagotchi/note_command"
require "samagotchi/send_command"
require "samagotchi/tools/send_note"
require "samagotchi/tools/delegate"
require "samagotchi/tools/delegate_result"
require "samagotchi/web/session_hub"

# A session id from outside (a bridge body, chi send/note arguments, a tool's
# arguments, a file name in the sessions dir) never becomes a path unless it
# is one: Session.valid_id? is the one check, and Session.session_dir /
# session_file refuse the rest. The web routes are in spec/web/routing_spec.rb.
RSpec.describe "session id check" do
  let(:root) { Dir.mktmpdir("session-id-check") }
  let(:state_dir) { File.join(root, "sessions").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:bad_ids) { ["../x", "..", "/tmp/x", "a/b", "a\0b", "", " ", "-x", "a" * 129, "x.json"] }

  after { FileUtils.rm_rf(root) }

  def make
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/work/app", test_run: false)
                       .tap { |s| s.save(state_dir: state_dir) }
  end

  # Nothing was written next to the sessions dir.
  def expect_nothing_outside
    expect(Dir.children(root)).to eq(["sessions"])
  end

  describe Samagotchi::Session do
    it "takes UUIDs, their prefixes and the plain ids specs use" do
      [SecureRandom.uuid, SecureRandom.uuid[0, 8], "s1", "sess_1-a"].each do |id|
        expect(described_class.valid_id?(id)).to be(true), id
        expect(described_class.session_dir(id, state_dir: state_dir)).to eq(File.join(state_dir, id))
      end
    end

    it "refuses anything else as a path: session_dir and session_file raise, exist? is false" do
      (bad_ids + [nil, 42]).each do |id|
        expect(described_class.valid_id?(id)).to be(false), id.inspect
        expect { described_class.session_dir(id, state_dir: state_dir) }
          .to raise_error(described_class::InvalidId), id.inspect
        expect { described_class.session_file(id, state_dir: state_dir) }
          .to raise_error(described_class::InvalidId), id.inspect
        expect(described_class.exist?(id, state_dir: state_dir)).to be(false)
        expect { described_class.load(id, state_dir: state_dir) }.to raise_error(ArgumentError)
      end
    end

    it "resolves a prefix to its id and hands a bad id back for the caller's not-found" do
      s = make
      expect(described_class.resolve_id(s.id[0, 8], state_dir: state_dir)).to eq(s.id)
      expect(described_class.resolve_id("../x", state_dir: state_dir)).to eq("../x")
    end

    it "lists no session whose file names a bad id" do
      good = make
      File.write(File.join(state_dir, "evil.json"),
                 JSON.generate(JSON.parse(File.read(described_class.session_file(good.id, state_dir: state_dir)))
                                   .merge("id" => "../evil")))
      expect(described_class.list(state_dir: state_dir).map(&:id)).to eq([good.id])
    end
  end

  describe Samagotchi::Bridge, "POST /turn" do
    let(:engine) do
      Samagotchi::Engine.new(client: instance_double(Samagotchi::Client), kernel: instance_double(Samagotchi::KernelLoop))
    end
    let(:bridge) { described_class.new(engine: engine, state_dir: state_dir, session_id: "s1") }

    it "answers 404 unknown_session for a bad session_id and writes nothing" do
      bad_ids.reject { |id| id.strip.empty? }.each do |id|
        _headers, status, body = bridge.send(:handle_post_turn, "s1", JSON.generate(session_id: id, prompt: "hi"))
        expect([status, body[:error]]).to eq([404, "unknown_session"]), id.inspect
        _headers, status, body = bridge.send(:handle_post_turn, id, JSON.generate(session_id: "s1", prompt: "hi"))
        expect([status, body[:error]]).to eq([404, "unknown_session"]), id.inspect
      end
      expect_nothing_outside
    end

    it "queues no turn for another session" do
      other = make
      _headers, status, = bridge.send(:handle_post_turn, "s1", JSON.generate(session_id: other.id, prompt: "hi"))
      expect(status).to eq(404)
      inbox = File.join(Samagotchi::Session.session_dir(other.id, state_dir: state_dir), Samagotchi::SessionInbox::INPUT_DIR)
      expect(Dir.exist?(inbox) ? Dir.children(inbox) : []).to be_empty
    end
  end

  describe "chi note and chi send" do
    let(:out) { StringIO.new }
    let(:err) { StringIO.new }

    def run(klass, *argv)
      klass.new(argv, stdin: StringIO.new("hello\n"), stdout: out, stderr: err, state_dir: state_dir).run
    end

    it "say no session for a bad id and write nothing" do
      ["../x", "/tmp/x", "a/b", "a\0b"].each do |id|
        [[Samagotchi::NoteCommand, id], [Samagotchi::SendCommand, id, "hi"]].each do |klass, *argv|
          err.truncate(0)
          err.rewind
          expect(run(klass, *argv)).not_to eq(0)
          expect(err.string).to include("no session"), "#{klass} #{id.inspect}"
        end
      end
      expect_nothing_outside
    end
  end

  describe "the peer tools" do
    let(:me) { make }
    let(:peers) { Samagotchi::Tools::Peers.new(session_id: me.id, cwd: "/work/app", state_dir: state_dir) }

    it "send_note, delegate (a follow-up) and delegate_result say no session for a bad id" do
      ["../x", "/tmp/x", "a/b", "a\0b"].each do |id|
        expect(Samagotchi::Tools::SendNote.call("hi", session: id, peers: peers)).to start_with("Error:"), id.inspect
        expect(Samagotchi::Tools::Delegate.call("hi", session: id, peers: peers))
          .to start_with("Error: no session"), id.inspect
        expect(Samagotchi::Tools::DelegateResult.call(session: id, peers: peers))
          .to start_with("Error: no session"), id.inspect
      end
      expect_nothing_outside
    end
  end

  describe Samagotchi::SessionManager do
    it "refuses a bad id to delete, archive, stop and deliver_turn" do
      ["../x", "/tmp/x", "a/b", "a\0b", ""].each do |id|
        expect { described_class.delete_session(id, state_dir: state_dir) }.to raise_error(ArgumentError)
        expect { described_class.archive_session(id, state_dir: state_dir) }.to raise_error(ArgumentError)
        expect { described_class.stop_session(id, state_dir: state_dir) }.to raise_error(ArgumentError)
        expect { described_class.deliver_turn(id, prompt: "hi", state_dir: state_dir) }.to raise_error(ArgumentError)
      end
      expect_nothing_outside
    end
  end

  describe Samagotchi::Web::SessionHub do
    it "leaves out a file whose name isn't an id and ignores a touch with a bad id" do
      good = make
      FileUtils.cp(Samagotchi::Session.session_file(good.id, state_dir: state_dir), File.join(state_dir, "a b.json"))
      hub = described_class.new(state_dir: state_dir)
      expect { hub.scan }.not_to raise_error
      expect { hub.touch("../x") }.not_to raise_error
      expect(hub.instance_variable_get(:@sessions).keys).to eq([good.id])
    end
  end
end
