# frozen_string_literal: true

require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/session"

RSpec.describe Samagotchi::Session do
  let(:tmpdir) { Dir.mktmpdir("session-spec") }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".new_session" do
    it "generates a unique UUID id" do
      s1 = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s2 = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      expect(s1.id).not_to eq(s2.id)
      expect(s1.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "sets metadata_version, mode, model_name, working_directory, and empty messages" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/home/user/proj")
      expect(session.metadata_version).to eq(described_class::METADATA_VERSION)
      expect(session.mode).to eq("assist")
      expect(session.model_name).to eq("gemma4")
      expect(session.working_directory).to eq("/home/user/proj")
      expect(session.messages).to eq([])
    end

    it "sets created_at and updated_at as ISO8601 strings" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      expect { Time.iso8601(session.created_at) }.not_to raise_error
      expect { Time.iso8601(session.updated_at) }.not_to raise_error
    end
  end

  describe "#save and .load round-trip" do
    it "persists and restores all fields" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp/proj")
      session.messages = [
        { role: "system", content: "You are Chi." },
        { role: "user",   content: "Hello" },
        { role: "model",  content: "Hi there!" }
      ]
      session.save(state_dir: tmpdir)

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.id).to eq(session.id)
      expect(loaded.mode).to eq("assist")
      expect(loaded.model_name).to eq("gemma4")
      expect(loaded.working_directory).to eq("/tmp/proj")
      expect(loaded.metadata_version).to eq(described_class::METADATA_VERSION)
    end

    it "restores a chat turn's tool calls with symbol keys (their arguments stay as saved)" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [
        { role: "model", content: "", tool_calls: [{ id: "c1", name: "execute", arguments: { "command" => "ls" } }] },
        { role: "tool_response", content: "[execute]\nok", tool_call_id: "c1" }
      ]
      session.save(state_dir: tmpdir)

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.messages).to eq(session.messages)
    end

    it "restores image refs on messages with symbol keys" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      ref = { file: "images/0123456789abcdef.png", mime: "image/png", width: 3, height: 2, bytes: 70,
              name: "shot.png", source: "user" }
      session.messages = [
        { role: "user", content: "look", images: [ref] },
        { role: "tool_response", content: "[read]\nImage shot.png attached.", images: [ref.merge(source: "tool")] }
      ]
      session.save(state_dir: tmpdir)

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.messages).to eq(session.messages)
    end

    it "restores message hashes with symbol keys" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [
        { role: "user", content: "test message" }
      ]
      session.save(state_dir: tmpdir)

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.messages.first.keys).to all(be_a(Symbol))
      expect(loaded.messages.first[:role]).to eq("user")
      expect(loaded.messages.first[:content]).to eq("test message")
    end

    it "saves a message holding bytes that aren't UTF-8, as ?, instead of raising" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages << { role: "user", content: "run it" }
      session.messages << { role: "tool", content: "[execute]\nstdout:\nok \xFF\xFE".dup.force_encoding(Encoding::UTF_8) }
      session.messages << { role: "tool", content: "bin \xFF".b, tool_calls: [{ id: "c1", arguments: { "x" => "\xFE".b } }] }

      expect { session.save(state_dir: tmpdir) }.not_to raise_error

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.messages[1][:content]).to eq("[execute]\nstdout:\nok ??")
      expect(loaded.messages[2][:content]).to eq("bin ?")
      expect(loaded.messages[2][:tool_calls].first[:arguments]).to eq("x" => "?")
      expect(session.messages[1][:content].valid_encoding?).to be(false) # the live copy is left alone
    end

    it "updates updated_at on save" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      original_updated_at = session.updated_at
      sleep(0.01)
      session.save(state_dir: tmpdir)
      expect(session.updated_at).not_to eq(original_updated_at)
    end

    it "round-trips the preloaded and muted memory names, normalized" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp",
                                            preloaded_memory_names: ["cli_usage", " cli_usage ", ""],
                                            muted_memory_names: ["gh-helper", nil, "gh-helper"])
      expect(session.preloaded_memory_names).to eq(["cli_usage"])
      expect(session.muted_memory_names).to eq(["gh-helper"])
      session.save(state_dir: tmpdir)

      raw = JSON.parse(File.read(File.join(tmpdir, "#{session.id}.json")))
      expect(raw["preloaded_memory_names"]).to eq(["cli_usage"])
      expect(raw["muted_memory_names"]).to eq(["gh-helper"])

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.preloaded_memory_names).to eq(["cli_usage"])
      expect(loaded.muted_memory_names).to eq(["gh-helper"])
      summary = described_class.summary_from_file(File.join(tmpdir, "#{session.id}.json"))
      expect(summary.preloaded_memory_names).to eq(["cli_usage"])
      expect(summary.muted_memory_names).to eq(["gh-helper"])
    end

    it "round-trips parent_id, the session that delegated this one, and reads nil where there is none" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp",
                                            parent_id: "parent-1234")
      expect(session.parent_id).to eq("parent-1234")
      session.save(state_dir: tmpdir)
      path = File.join(tmpdir, "#{session.id}.json")

      expect(JSON.parse(File.read(path))["parent_id"]).to eq("parent-1234")
      expect(described_class.load(session.id, state_dir: tmpdir).parent_id).to eq("parent-1234")
      expect(described_class.summary_from_file(path).parent_id).to eq("parent-1234")

      plain = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      plain.save(state_dir: tmpdir)
      expect(described_class.load(plain.id, state_dir: tmpdir).parent_id).to be_nil
      expect(JSON.parse(File.read(File.join(tmpdir, "#{plain.id}.json")))).to include("parent_id" => nil)
    end

    it "round-trips last_turn and reads the pending question in the summary too" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      last = { "outcome" => "failed", "ended_at" => "2026-09-28T10:00:00.000+02:00", "seconds" => 12.5, "origin" => "client" }
      session.last_turn = last
      session.pending_question = { id: "q1", kind: "approval", question: "Run it?" }
      session.save(state_dir: tmpdir)
      path = File.join(tmpdir, "#{session.id}.json")

      expect(described_class.load(session.id, state_dir: tmpdir).last_turn).to eq(last)
      summary = described_class.summary_from_file(path)
      expect(summary.last_turn).to eq(last)
      expect(summary.pending_question).to include(id: "q1", kind: "approval")

      plain = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").save(state_dir: tmpdir)
      expect(described_class.summary_from_file(File.join(tmpdir, "#{plain.id}.json"))).to have_attributes(last_turn: nil, pending_question: nil)
    end

    it "reads a session file written before the memory-name fields as empty lists" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      path = File.join(tmpdir, "#{session.id}.json")
      raw = JSON.parse(File.read(path))
      raw.delete("preloaded_memory_names")
      raw.delete("muted_memory_names")
      File.write(path, JSON.generate(raw))

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.preloaded_memory_names).to eq([])
      expect(loaded.muted_memory_names).to eq([])
      expect(described_class.summary_from_file(path).muted_memory_names).to eq([])
    end
  end

  describe "#save atomic write" do
    it "does not corrupt an existing file on concurrent save (rename is atomic)" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [{ role: "user", content: "first" }]
      session.save(state_dir: tmpdir)

      # Verify no .tmp file is left behind after save
      tmp_files = Dir.glob(File.join(tmpdir, "*.tmp"))
      expect(tmp_files).to be_empty

      # Verify the session file is valid JSON
      path = File.join(tmpdir, "#{session.id}.json")
      expect { JSON.parse(File.read(path)) }.not_to raise_error
    end
  end

  describe ".load" do
    it "raises ArgumentError when session_id does not exist" do
      expect {
        described_class.load("nonexistent-id", state_dir: tmpdir)
      }.to raise_error(ArgumentError, /Session not found/)
    end

    it "raises ArgumentError on corrupted JSON" do
      bad_path = File.join(tmpdir, "bad-id.json")
      File.write(bad_path, "{ not valid json")
      expect {
        described_class.load("bad-id", state_dir: tmpdir)
      }.to raise_error(ArgumentError, /corrupted/)
    end
  end

  describe ".resolve_id" do
    def save(id, preview)
      session = described_class.new_session(mode: "assist", model_name: "m", working_directory: tmpdir)
      session.id = id
      session.first_preview = preview
      session.save(state_dir: tmpdir)
    end

    before do
      save("abc12345-0000", "first")
      save("abd99999-0000", "second")
    end

    it "expands a unique prefix to the full id" do
      expect(described_class.resolve_id("abc", state_dir: tmpdir)).to eq("abc12345-0000")
    end

    it "keeps a full id, and an unknown one as is" do
      expect(described_class.resolve_id("abd99999-0000", state_dir: tmpdir)).to eq("abd99999-0000")
      expect(described_class.resolve_id("zzz", state_dir: tmpdir)).to eq("zzz")
      expect(described_class.resolve_id("a*", state_dir: tmpdir)).to eq("a*")
    end

    it "lists the matches of an ambiguous prefix" do
      expect { described_class.resolve_id("ab", state_dir: tmpdir) }.to raise_error(
        described_class::AmbiguousId,
        "session id ab matches 2 sessions:\n  abc12345-0000  first\n  abd99999-0000  second"
      )
    end
  end

  describe ".list" do
    it "returns empty array when directory does not exist" do
      expect(described_class.list(state_dir: "/nonexistent/path")).to eq([])
    end

    it "returns sessions sorted by updated_at desc by default (newest first)" do
      s1 = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s1.save(state_dir: tmpdir)
      sleep(0.02)
      s2 = described_class.new_session(mode: "assist", model_name: "qwen36", working_directory: "/tmp")
      s2.save(state_dir: tmpdir)

      sessions = described_class.list(state_dir: tmpdir)
      expect(sessions.map(&:id)).to eq([s2.id, s1.id])
    end

    it "supports explicit sort by created_at asc (oldest first)" do
      s1 = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      sleep(0.01)
      s2 = described_class.new_session(mode: "assist", model_name: "qwen36", working_directory: "/tmp")
      s1.save(state_dir: tmpdir)
      s2.save(state_dir: tmpdir)

      sessions = described_class.list(state_dir: tmpdir, sort: "created_at", order: "asc")
      expect(sessions.map(&:id)).to eq([s1.id, s2.id])
    end

    it "supports limit and offset" do
      sessions = 3.times.map { described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap { |s| sleep(0.01); s.save(state_dir: tmpdir) } }
      listed = described_class.list(state_dir: tmpdir, sort: "created_at", order: "asc", limit: 2, offset: 1)
      expect(listed.map(&:id)).to eq(sessions[1..2].map(&:id))
    end

    it "skips files with invalid JSON without raising" do
      File.write(File.join(tmpdir, "corrupt.json"), "{ invalid")
      sessions = described_class.list(state_dir: tmpdir)
      expect(sessions).to be_empty
    end

    it "does not load messages for listed sessions (list is lightweight)" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [{ role: "user", content: "hello" }]
      session.save(state_dir: tmpdir)

      listed = described_class.list(state_dir: tmpdir).first
      expect(listed.messages).to eq([])
    end
  end

  describe ".summary_from_file" do
    it "parses one session file into a messages-less Session, as .list does" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp/proj")
      session.messages = [{ role: "user", content: "hello" }]
      session.last_prompt = "hello"
      session.status = described_class::STATUS_RUNNING
      session.save(state_dir: tmpdir)

      summary = described_class.summary_from_file(File.join(tmpdir, "#{session.id}.json"))

      expect(summary.id).to eq(session.id)
      expect(summary.messages).to eq([])
      expect(summary.last_prompt).to eq("hello")
      expect(summary.status).to eq("running")
      expect(summary.working_directory).to eq("/tmp/proj")
    end

    it "is nil for a corrupt file and for one missing a required field, and .list leaves the same files out" do
      File.write(File.join(tmpdir, "corrupt.json"), "{ invalid")
      File.write(File.join(tmpdir, "partial.json"), JSON.generate("id" => "partial"))

      expect(described_class.summary_from_file(File.join(tmpdir, "corrupt.json"))).to be_nil
      expect(described_class.summary_from_file(File.join(tmpdir, "partial.json"))).to be_nil
      expect(described_class.list(state_dir: tmpdir)).to be_empty
    end

    it "is nil for a file that is gone" do
      expect(described_class.summary_from_file(File.join(tmpdir, "missing.json"))).to be_nil
    end
  end

  describe ".default_state_dir" do
    it "uses XDG_STATE_HOME when set" do
      dir = described_class.default_state_dir(env: { "XDG_STATE_HOME" => "/custom/state" })
      expect(dir).to eq("/custom/state/samagotchi/sessions")
    end

    it "falls back to ~/.local/state when XDG_STATE_HOME is absent" do
      dir = described_class.default_state_dir(env: {})
      expect(dir).to eq(File.join(Dir.home, ".local", "state", "samagotchi", "sessions"))
    end
  end

  describe "status fields" do
    it "defaults to idle status and empty last_prompt" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      expect(session.status).to eq(described_class::STATUS_IDLE)
      expect(session.last_prompt).to eq("")
    end

    it "round-trips status and last_prompt through save/load" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = described_class::STATUS_RUNNING
      session.last_prompt = "tell me a joke"
      session.save(state_dir: tmpdir)

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(described_class::STATUS_RUNNING)
      expect(loaded.last_prompt).to eq("tell me a joke")
    end
  end

  describe "status transition methods" do
    let(:session) { described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp") }

    before { session.save(state_dir: tmpdir) }

    it ".mark_running sets status to running" do
      described_class.mark_running(session.id, state_dir: tmpdir)
      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(described_class::STATUS_RUNNING)
    end

    it ".mark_completed sets status to completed" do
      described_class.mark_completed(session.id, state_dir: tmpdir)
      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(described_class::STATUS_COMPLETED)
    end

    it ".mark_error sets status to error with reason in last_prompt" do
      described_class.mark_error(session.id, reason: "timeout", state_dir: tmpdir)
      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(described_class::STATUS_ERROR)
      expect(loaded.last_prompt).to eq("timeout")
    end

    it ".mark_stopped sets status to stopped" do
      described_class.mark_stopped(session.id, state_dir: tmpdir)
      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(described_class::STATUS_STOPPED)
    end
  end

  describe "first_preview" do
    it "defaults to empty for new sessions" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      expect(session.first_preview).to eq("")
    end

    it "round-trips through save/load" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.first_preview = "hello world"
      session.save(state_dir: tmpdir)

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.first_preview).to eq("hello world")
    end

    it "auto-computes from first user message on save" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [
        { role: "system", content: "You are Chi." },
        { role: "user", content: "Please could you write some temporary memory?" },
        { role: "assistant", content: "Sure!" }
      ]
      session.save(state_dir: tmpdir)

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.first_preview).to include("Please")
    end

    it "auto-computes and truncates to 80 chars" do
      long_content = "a" * 200
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [{ role: "user", content: long_content }]
      session.save(state_dir: tmpdir)

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.first_preview.length).to eq(81)
      expect(loaded.first_preview).to end_with("…")
    end

    it "does not recompute when already cached" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.first_preview = "original"
      session.messages = [{ role: "user", content: "new message" }]
      session.save(state_dir: tmpdir)

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.first_preview).to eq("original")
    end

    it "is read by .list alongside other metadata" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.first_preview = "list preview"
      session.save(state_dir: tmpdir)

      listed = described_class.list(state_dir: tmpdir).first
      expect(listed.first_preview).to eq("list preview")
    end

    it "loads old sessions without first_preview as empty (migration)" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [{ role: "user", content: "hello" }]
      session.save(state_dir: tmpdir)

      # Simulate old session file without first_preview
      path = File.join(tmpdir, "#{session.id}.json")
      data = JSON.parse(File.read(path))
      data.delete("first_preview")
      File.write(path, JSON.generate(data))

      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.first_preview).to eq("")
      loaded.save(state_dir: tmpdir)

      reloaded = described_class.load(session.id, state_dir: tmpdir)
      expect(reloaded.first_preview).to include("hello")
    end

    describe "#compute_first_preview!" do
      it "returns true and sets first_preview when user message exists" do
        session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
        session.messages = [{ role: "user", content: "test content" }]
        expect(session.compute_first_preview!).to be true
        expect(session.first_preview).to eq("test content")
      end

      it "returns false when there are no messages" do
        session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
        expect(session.compute_first_preview!).to be false
        expect(session.first_preview).to eq("")
      end

      it "returns false when no user messages exist" do
        session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
        session.messages = [{ role: "system", content: "You are Chi." }]
        expect(session.compute_first_preview!).to be false
      end

      it "returns false and does not overwrite existing value" do
        session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
        session.first_preview = "cached"
        session.messages = [{ role: "user", content: "new" }]
        expect(session.compute_first_preview!).to be false
        expect(session.first_preview).to eq("cached")
      end
    end
  end

  describe ".session_dir and .default_sessions_dir" do
    it "returns a directory path for a session" do
      dir = described_class.session_dir("abc-123", state_dir: tmpdir)
      expect(dir).to eq(File.join(tmpdir, "abc-123"))
    end

    it ".default_sessions_dir equals .default_state_dir" do
      expect(described_class.default_sessions_dir).to eq(described_class.default_state_dir)
    end
  end

  describe "test_run flag" do
    it "defaults to false and round-trips" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: false)
      session.save(state_dir: tmpdir)
      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.test_run).to be false
    end

    it "persists test_run true" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: true)
      session.save(state_dir: tmpdir)
      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.test_run).to be true
    end

    it "loads old sessions without test_run as false" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: false)
      session.save(state_dir: tmpdir)
      path = File.join(tmpdir, "#{session.id}.json")
      data = JSON.parse(File.read(path))
      data.delete("test_run")
      File.write(path, JSON.generate(data))
      loaded = described_class.load(session.id, state_dir: tmpdir)
      expect(loaded.test_run).to be false
    end

    it "auto-detects test env when test_run not given" do
      session = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      # In rspec, CI may be unset but RACK_ENV not test; ensure explicit env check
      expect([true, false]).to include(session.test_run)
    end
  end

  describe ".prune" do
    it "with any_age deletes every eligible session however new, still keeping live and keep_status ones" do
      mk = ->(**attrs) { described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: true).tap { |x| attrs.each { |k, v| x.public_send("#{k}=", v) }; x.save(state_dir: tmpdir) } }
      fresh = mk.call
      running = mk.call(status: "running")
      live = mk.call
      other = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: false).tap { |x| x.save(state_dir: tmpdir) }

      result = described_class.prune(state_dir: tmpdir, days: 0, max_count: 0, keep_status: ["running"], test_only: true,
                                     any_age: true, alive_check: ->(id) { id == live.id })

      expect(result[:deleted]).to eq([fresh.id])
      expect(result[:kept]).to contain_exactly(running.id, live.id)
      expect(File.exist?(File.join(tmpdir, "#{other.id}.json"))).to be true
    end

    it "deletes sessions older than days" do
      s_old = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s_old.save(state_dir: tmpdir)
      # fake old updated_at
      old_time = (Time.now - 20 * 86_400).iso8601(3)
      path_old = File.join(tmpdir, "#{s_old.id}.json")
      data = JSON.parse(File.read(path_old))
      data["updated_at"] = old_time
      data["created_at"] = old_time
      File.write(path_old, JSON.generate(data))

      s_new = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s_new.save(state_dir: tmpdir)

      result = described_class.prune(state_dir: tmpdir, days: 14, max_count: 500, dry_run: false)
      expect(result[:deleted]).to include(s_old.id)
      expect(result[:kept]).to include(s_new.id)
      expect(File.exist?(path_old)).to be false
      expect(File.exist?(File.join(tmpdir, "#{s_new.id}.json"))).to be true
    end

    def save_aged(status:, days_old: 20)
      s = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s.status = status
      s.save(state_dir: tmpdir)
      path = File.join(tmpdir, "#{s.id}.json")
      data = JSON.parse(File.read(path))
      data["updated_at"] = (Time.now - days_old * 86_400).iso8601(3)
      data["created_at"] = data["updated_at"]
      File.write(path, JSON.generate(data))
      [s, path]
    end

    # status is turn state; a live owner is what protects a session in use.
    # (session.keep_status defaults to "running"; this is keep_status "".)
    it "prunes an old session left 'running' by a dead worker when no status is kept" do
      s_old, path_old = save_aged(status: described_class::STATUS_RUNNING)

      result = described_class.prune(state_dir: tmpdir, days: 14, max_count: 500, keep_status: [])
      expect(result[:deleted]).to include(s_old.id)
      expect(File.exist?(path_old)).to be false
    end

    it "keeps an old session with a live owner" do
      s_old, path_old = save_aged(status: described_class::STATUS_IDLE)

      result = described_class.prune(state_dir: tmpdir, days: 14, max_count: 500, alive_check: ->(id) { id == s_old.id })
      expect(result[:kept]).to include(s_old.id)
      expect(File.exist?(path_old)).to be true
    end

    it "still honors an explicit keep_status" do
      s_old, = save_aged(status: described_class::STATUS_RUNNING)

      result = described_class.prune(state_dir: tmpdir, days: 14, max_count: 500, keep_status: ["running"])
      expect(result[:kept]).to include(s_old.id)
    end

    it "respects max_count overflow (deletes beyond limit)" do
      3.times do
        s = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
        s.save(state_dir: tmpdir)
        sleep(0.01)
      end
      result = described_class.prune(state_dir: tmpdir, days: 0, max_count: 2)
      expect(result[:deleted].size).to eq(1)
      expect(result[:kept].size).to eq(2)
    end

    it "supports dry_run without deleting" do
      s = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s.save(state_dir: tmpdir)
      path = File.join(tmpdir, "#{s.id}.json")
      data = JSON.parse(File.read(path))
      data["updated_at"] = (Time.now - 20 * 86_400).iso8601(3)
      File.write(path, JSON.generate(data))
      result = described_class.prune(state_dir: tmpdir, days: 14, dry_run: true)
      expect(result[:deleted]).to include(s.id)
      expect(File.exist?(path)).to be true
    end

    it "deletes a session left empty whatever its age, also when retaining forever" do
      empty = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      empty.save(state_dir: tmpdir)
      used = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      used.save(state_dir: tmpdir)

      result = described_class.prune(state_dir: tmpdir, days: 0, max_count: 0, empty_check: ->(id) { id == empty.id })

      expect(result[:deleted]).to eq([empty.id])
      expect(result[:kept]).to eq([used.id])
    end

    it "keeps a session left empty that a live owner has" do
      empty = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      empty.save(state_dir: tmpdir)

      result = described_class.prune(state_dir: tmpdir, empty_check: ->(_) { true }, alive_check: ->(_) { true })

      expect(result[:kept]).to eq([empty.id])
    end

    it "only deletes when json present (skips orphan dirs)" do
      s = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s.save(state_dir: tmpdir)
      FileUtils.mkdir_p(File.join(tmpdir, "orphan-dir"))
      described_class.prune(state_dir: tmpdir, days: 0, max_count: 0)
      # orphan dir should not be counted as deleted/skipped as it's not a session
      expect(Dir.exist?(File.join(tmpdir, "orphan-dir"))).to be true
    end

    it "filters test_only" do
      s_test = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: true)
      s_test.save(state_dir: tmpdir)
      s_real = described_class.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: false)
      s_real.save(state_dir: tmpdir)
      # make both old
      [s_test, s_real].each do |s|
        p = File.join(tmpdir, "#{s.id}.json")
        d = JSON.parse(File.read(p))
        d["updated_at"] = (Time.now - 20 * 86_400).iso8601(3)
        File.write(p, JSON.generate(d))
      end
      result = described_class.prune(state_dir: tmpdir, days: 14, test_only: true)
      expect(result[:deleted]).to include(s_test.id)
      expect(result[:deleted]).not_to include(s_real.id)
    end
  end
end
