# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/engine"
require "samagotchi/session_manager"
require "samagotchi/bridge"
require "samagotchi/reminder_store"
require_relative "../support/session_manager_context"

RSpec.describe Samagotchi::SessionManager do
  include_context "session manager files"

  describe ".delete_session" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let(:session_file) { File.join(tmpdir, "#{session.id}.json") }

    def fill_session_dir
      %w[input output notes images].each { |sub| FileUtils.mkdir_p(File.join(session_dir, sub)) }
      File.write(File.join(session_dir, "notes", "1.json"), "{}")
      File.write(File.join(session_dir, "images", "ab.png"), "png")
      File.write(File.join(session_dir, "output", "1.txt"), "answer")
    end

    it "removes the session file and its whole directory, and says what it removed" do
      fill_session_dir

      result = described_class.delete_session(session.id, state_dir: tmpdir)

      expect(result).to eq(id: session.id, removed: [session_file, session_dir], stopped: false)
      expect(File.exist?(session_file)).to be false
      expect(Dir.exist?(session_dir)).to be false
    end

    it "removes the plugins' state for the session (plugins/<bundle>/sessions/<id>.json or <id>/), not another's" do
      plugins = File.join(Samagotchi::Paths.state_dir, "plugins")
      own = File.join(plugins, "check-in", "sessions", "#{session.id}.json")
      own_dir = File.join(plugins, "other", "sessions", session.id)
      kept = File.join(plugins, "check-in", "sessions", "someone-else.json")
      [own, kept].each { |f| FileUtils.mkdir_p(File.dirname(f)) && File.write(f, "{}") }
      FileUtils.mkdir_p(own_dir)

      described_class.delete_session(session.id, state_dir: tmpdir)

      expect([File.exist?(own), Dir.exist?(own_dir), File.exist?(kept)]).to eq([false, false, true])
    ensure
      FileUtils.rm_rf(plugins)
    end

    it "removes the session's attached context (context/sessions/<id>/), not another's" do
      require "samagotchi/context_sources"
      own = Samagotchi::ContextSources.session_location(session.id, state_dir: tmpdir)
      other = Samagotchi::ContextSources.session_location("11111111-2222-3333-4444-555555555555", state_dir: tmpdir)
      [own, other].each { |loc| loc.mute("pr-1") }

      result = described_class.delete_session(session.id, state_dir: tmpdir)

      expect(result[:removed]).to include(own.dir)
      expect([Dir.exist?(own.dir), Dir.exist?(other.dir)]).to eq([false, true])
    ensure
      # The root is next to tmpdir, shared with other spec processes: only ours goes.
      [own, other].each { |loc| FileUtils.rm_rf(loc.dir) }
    end

    it "takes a unique id prefix" do
      result = described_class.delete_session(session.id[0, 6], state_dir: tmpdir)

      expect(result[:id]).to eq(session.id)
      expect(File.exist?(session_file)).to be false
    end

    it "refuses an ambiguous prefix and removes nothing" do
      now = Time.now.utc.iso8601
      Samagotchi::Session.new(id: "#{session.id[0, 4]}-other", mode: "assist", model_name: "gemma4",
                              working_directory: "/tmp", messages: [], created_at: now, updated_at: now)
                         .save(state_dir: tmpdir)

      expect { described_class.delete_session(session.id[0, 4], state_dir: tmpdir) }
        .to raise_error(Samagotchi::Session::AmbiguousId)
      expect(File.exist?(session_file)).to be true
    end

    it "refuses an unknown id, and one that is not an id" do
      FileUtils.mkdir_p(File.join(tmpdir, "keep"))

      expect { described_class.delete_session("nope", state_dir: tmpdir) }
        .to raise_error(ArgumentError, "no session nope")
      expect { described_class.delete_session("../#{File.basename(tmpdir)}", state_dir: tmpdir) }
        .to raise_error(ArgumentError, /no session/)
      expect { described_class.delete_session("", state_dir: tmpdir) }.to raise_error(ArgumentError)
      expect(Dir.exist?(File.join(tmpdir, "keep"))).to be true
    end

    it "refuses while a worker owns the session, and removes nothing" do
      fill_session_dir
      spawn_owner

      expect { described_class.delete_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::DeleteRefused) { |e| expect(e.reason).to eq(:worker_running) }
      expect(File.exist?(session_file)).to be true
      expect(described_class.session_owner(session.id, state_dir: tmpdir)).not_to be_nil
    end

    # A worker being started holds no lock yet: the delete refuses it as
    # it refuses an owned one, rather than pull the files from under it.
    it "refuses while a worker is being started for it (the starting marker), and removes nothing" do
      fill_session_dir
      Samagotchi::StartingMarker.mark(session.id, state_dir: tmpdir)

      expect { described_class.delete_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::DeleteRefused) { |e| expect(e.reason).to eq(:worker_running) }
      expect(File.exist?(session_file)).to be true
    end

    it "with stop: stops a worker being started, waits for it, then deletes" do
      Samagotchi::StartingMarker.mark(session.id, state_dir: tmpdir)
      # The worker takes the lock, sees the stop and leaves (Worker#start
      # clears the marker as it takes the session).
      allow(described_class).to receive(:stop_session).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { Samagotchi::StartingMarker.clear(session.id, state_dir: tmpdir) }
      end

      result = described_class.delete_session(session.id, state_dir: tmpdir, stop: true, wait: 5)

      expect(result).to include(id: session.id, stopped: true)
      expect(File.exist?(session_file)).to be false
    end

    it "with stop: removes nothing while the start outlives the wait" do
      Samagotchi::StartingMarker.mark(session.id, state_dir: tmpdir)

      expect { described_class.delete_session(session.id, state_dir: tmpdir, stop: true, wait: 0.2) }
        .to raise_error(described_class::DeleteRefused) { |e| expect(e.reason).to eq(:still_stopping) }
      expect(File.exist?(session_file)).to be true
    end

    it "with stop: stops the worker first, then deletes" do
      fill_session_dir
      spawn_owner

      result = described_class.delete_session(session.id, state_dir: tmpdir, stop: true, wait: 5)

      expect(result).to include(id: session.id, stopped: true)
      expect(File.exist?(session_file)).to be false
      expect(Dir.exist?(session_dir)).to be false
    end

    it "with stop: removes nothing when the worker outlives the wait" do
      spawn_owner(ignore_term: true)

      expect { described_class.delete_session(session.id, state_dir: tmpdir, stop: true, wait: 0.3) }
        .to raise_error(described_class::DeleteRefused) { |e| expect(e.reason).to eq(:still_stopping) }
      expect(Dir.exist?(session_dir)).to be true
      expect(File.exist?(session_file)).to be true
    end

    it "refuses a session a one-turn chi run owns, even with stop:" do
      lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "tui")
      allow(Process).to receive(:kill)

      expect { described_class.delete_session(session.id, state_dir: tmpdir, stop: true) }
        .to raise_error(described_class::OwnedByTUI)
      expect(Process).not_to have_received(:kill)
      expect(File.exist?(session_file)).to be true
    ensure
      lock&.release
    end

    it "removes a directory left without its session file" do
      FileUtils.mkdir_p(session_dir)
      FileUtils.rm_f(session_file)

      expect(described_class.delete_session(session.id, state_dir: tmpdir)[:removed]).to eq([session_dir])
    end
  end
end
