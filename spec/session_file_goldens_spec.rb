# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "spec_helper"
require "samagotchi/session"
require "samagotchi/verify_fresh_origin"

# A session file's bytes (characterization): what #save writes for every
# field, what a load→save of an older or a newer chi's file writes, and the
# casts and defaults behind them. Pinned before Session's fields became one
# table (Session::FIELDS rows), which must keep every file byte-identical.
# The golden is the file exactly as #save writes it, but for two
# placeholders: the spec's tmpdir is <TMP> and this chi's VERSION is
# <VERSION>. The *_in.json files are hand-written inputs (a newer chi's,
# an old chi's file), never regenerated.
#
# Regenerate only after an intended change to the file's bytes:
#   UPDATE_GOLDENS=1 bundle exec rspec spec/session_file_goldens_spec.rb
RSpec.describe "Session file goldens (characterization)" do
  let(:golden_dir) { File.expand_path("fixtures/session_goldens", __dir__) }
  let(:tmp) { Dir.mktmpdir("session-goldens") }
  let(:state_dir) { File.join(tmp, "sessions") }
  let(:now) { Time.utc(2026, 11, 8, 12, 0, 0) }
  let(:later) { Time.utc(2026, 11, 8, 12, 5, 0) }

  after { FileUtils.rm_rf(tmp) }

  def session_class = Samagotchi::Session

  def normalize(text)
    text.gsub(tmp, "<TMP>").gsub(%("written_by": #{Samagotchi::VERSION.to_json}), %("written_by": "<VERSION>"))
  end

  def expect_golden(name, text)
    path = File.join(golden_dir, name)
    text = normalize(text)
    if ENV["UPDATE_GOLDENS"] == "1"
      FileUtils.mkdir_p(golden_dir)
      File.write(path, text)
    end
    expect(text).to eq(File.read(path)), "#{name} differs from its golden"
  end

  def file_text(id) = File.read(session_class.session_file(id, state_dir: state_dir))

  def saved_text(session)
    session.save(state_dir: state_dir, now: later)
    file_text(session.id)
  end

  # A hand-written input file, with <TMP> as the spec's tmpdir, saved as
  # the session +id+'s file.
  def place_input(name, id)
    FileUtils.mkdir_p(state_dir)
    text = File.read(File.join(golden_dir, name)).gsub("<TMP>", tmp)
    File.write(session_class.session_file(id, state_dir: state_dir), text)
  end

  def load_save(id) = saved_text(session_class.load(id, state_dir: state_dir))

  def minimal(id: "golden-0000-minimal", **attrs)
    session_class.new(id: id, mode: "assist", model_name: "main:gemma-small", working_directory: "/work/project",
                      messages: [], created_at: "2026-11-08T11:00:00.000Z", updated_at: "2026-11-08T11:00:00.000Z",
                      **attrs)
  end

  def git_repo(path)
    FileUtils.mkdir_p(path)
    _, status = Open3.capture2e("git", "init", "-q", path)
    raise "git init failed" unless status.success?

    path
  end

  # Every FIELDS key away from its default, through the public writers.
  def every_field_session
    minimal(id: "golden-0001-every-field").tap do |s|
      s.model_typed = "small"
      s.messages = [
        { role: "user", content: "fix the parser", turn_id: "11111111-1111-4111-8111-111111111111",
          source: { kind: "steer", author: "p:alice" },
          images: [{ file: "img/1.png", mime: "image/png", width: 10, height: 20 }] },
        { role: "model", content: "", tool_calls: [{ id: "c1", name: "read", arguments: { "path" => "a.rb" } }] },
        { role: "tool_response", content: "ok", name: "read" },
        { role: "model", content: "",
          empty_answer: { steps: [{ tool: "read", ok: true }], refusal: { kind: "safety", text: "no" } } }
      ]
      s.status = "error"
      s.last_prompt = "fix the parser"
      s.first_preview = "fix the parser"
      s.title = "Parser fix"
      s.test_run = true
      s.pending_question = Samagotchi::PendingQuestion.new(
        id: "q-1", question: "Allow write?", options: %w[Allow Deny], header: "Approval", multi_select: false,
        allow_freeform: true, kind: "approval", approval: { "tool" => "write" }, status: "pending",
        created_at: "2026-11-08T11:30:00.000Z"
      )
      s.used_memory_names = %w[system/style project/notes]
      s.project_root = "/work/project"
      s.preloaded_memory_names = ["system/delegated"]
      s.muted_memory_names = ["system/noisy"]
      s.prompt_notes = [{ "name" => "model_notes_gemma", "scope" => "system", "chars" => 612, "digest" => "abc123" },
                        Samagotchi::PromptNote.new(name: "model_notes_x", scope: "project", chars: 80, digest: "def456")]
      s.parent_id = "golden-0002-parent"
      s.scratch = true
      s.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: "2026-11-08T11:40:00.000Z", seconds: 4.5,
                                             origin: "user", enqueued_id: "e-1")
      s.verdicts = [{ check_turn_id: "t-1", verdict: "holds", detail: { reason: "spec passes", lines: [1, 2] } }]
      s.delegate = true
      s.llm_context = Samagotchi::LLMContextOverride.new(strategy: %i[stale forget], apply: :turn_end,
                                                         budget_tokens: 64_000)
      s.continues = "golden-0003-previous"
      s.thinking = :high
      s.reasoning_history = :all
      s.appended_prompt_files = ["/work/extra.md", "/work/more.md"]
      s.toolkit = Samagotchi::Toolkit.new(name: "lean", add: ["web_fetch"], remove: ["memory_write"])
      s.toolkit_origin = "suggested"
      s.settings = Samagotchi::SessionConfig::Settings.new(core: { "recap.enabled" => false },
                                                           bundles: { "cost-cap" => { "cap" => 5 } })
      s.interrupted_turn = Samagotchi::InterruptedTurn.new(id: "t-2", started_at: "2026-11-08T11:50:00.000Z",
                                                           at: "2026-11-08T11:51:00.000Z", iteration: 3)
      s.parent_answers = "soft"
      s.working_set_pins = [{ "kind" => "file", "key" => "/work/project/lib/a.rb" },
                            Samagotchi::WorkingSetPin.new(kind: "memory", key: "project/notes")]
      s.review = Samagotchi::SessionReview.new(subjects: ["lib/a.rb", "PR #12"], from: "golden-0004-source")
      s.first_turn_id = "22222222-2222-4222-8222-222222222222"
      s.verify_fresh = { "author" => "p:alice", "mode" => "pair", "of" => "t-1",
                         "anchor" => { "turn_id" => "33333333-3333-4333-8333-333333333333", "quote" => "it holds" } }
    end
  end

  describe "the codec" do
    it "writes every field away from its default, and a load→save writes the same bytes" do
      session = every_field_session
      expect(session_class::FIELDS.keys - JSON.parse(saved_text(session)).keys).to eq([])
      expect_golden("every_field.json", file_text(session.id))
      expect_golden("every_field.json", load_save(session.id))
    end

    it "writes a new session with nothing set: no optional keys, the fresh defaults" do
      allow(SecureRandom).to receive(:uuid).and_return("golden-0005-defaults")
      allow(session_class).to receive(:test_session_env?).and_return(true)
      session = session_class.new_session(mode: "assist", model_name: "main:gemma-small",
                                          working_directory: File.join(tmp, "folder"), now: now)
      expect_golden("defaults.json", saved_text(session))
    end

    it "builds #to_h before any save with the fresh metadata_version (the file default is 1)" do
      expect_golden("unsaved_to_h.json", "#{JSON.pretty_generate(minimal.to_h)}\n")
    end

    it "keeps a newer chi's file: its unknown keys, the levels it can't read (unstripped), as today" do
      place_input("newer_writer_in.json", "golden-0006-newer")
      expect_golden("newer_writer_out.json", load_save("golden-0006-newer"))
    end

    it "grows an old (0.130-era) file by the keys a save adds; a project_root it never had stays null in a repo" do
      git_repo(File.join(tmp, "repo"))
      place_input("old_file_in.json", "golden-0007-old")
      expect(session_class.load("golden-0007-old", state_dir: state_dir).project_root).not_to be_nil
      expect_golden("old_file_out.json", load_save("golden-0007-old"))
    end

    it "reads a key present as null as null (not its default), then casts it" do
      place_input("nulls_in.json", "golden-0008-nulls")
      expect_golden("nulls_out.json", load_save("golden-0008-nulls"))
    end

    it "keeps the plain writers raw (a nil test_run saves false, a nil scratch null) and a load casts them" do
      session = minimal(id: "golden-0009-raw")
      session.test_run = nil
      session.scratch = nil
      session.delegate = nil
      session.used_memory_names = ["system/a", "system/a", " system/b "]
      session.preloaded_memory_names = nil
      session.appended_prompt_files = ["/a.md", "/a.md", "", :"/b.md"]
      expect_golden("raw_writers.json", saved_text(session))
      expect_golden("raw_writers_reloaded.json", load_save(session.id))
    end

    it "writes a running turn's checkpoint in place of its messages, and the real ones once it ends" do
      session = minimal(id: "golden-0010-mid-turn")
      session.messages = [{ role: "user", content: "before" }]
      session.status = session_class::STATUS_RUNNING
      session.turn_checkpoint = {
        messages: [{ role: "user", content: "before" }, { role: "user", content: "now" },
                   { role: "model", content: "half", tool_calls: [{ id: "c1", name: "read", arguments: {} }] }],
        marker: Samagotchi::InterruptedTurn.new(id: "t-9", started_at: "2026-11-08T11:58:00.000Z", iteration: 1)
      }
      expect_golden("mid_turn.json", saved_text(session))
      session.messages = [{ role: "user", content: "before" }, { role: "user", content: "now" },
                          { role: "model", content: "done" }]
      session.status = session_class::STATUS_IDLE
      expect_golden("mid_turn_ended.json", saved_text(session))
    end

    it "scrubs bytes that aren't UTF-8 in messages, the pending question and the verdicts" do
      bad = (+"caf\xC3").force_encoding(Encoding::BINARY)
      session = minimal(id: "golden-0011-scrub")
      # A preview of its own: #save's first_preview from such a message
      # raises (not scrubbed: a gap of its own, not pinned here).
      session.first_preview = "scrub"
      session.messages = [{ role: "user", content: bad }]
      session.pending_question = { "id" => "q-2", "question" => bad }
      session.verdicts = [{ "verdict" => bad, "detail" => { "why" => bad } }]
      expect_golden("scrub.json", saved_text(session))
    end

    it "refuses a session without an id, or with a keyword it doesn't know (ArgumentError)" do
      expect do
        session_class.new(mode: "assist", model_name: "m", working_directory: "/w", messages: [],
                          created_at: "x", updated_at: "x")
      end.to raise_error(ArgumentError)
      expect { minimal(colour: "blue") }.to raise_error(ArgumentError)
    end
  end
end
