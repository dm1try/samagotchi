# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/review_start"
require "samagotchi/session_manager"
require "samagotchi/session_continue"

# ReviewStart: review sessions (chi review, the web's Start review).
RSpec.describe Samagotchi::ReviewStart do
  let(:state_dir) { Dir.mktmpdir("review-state") }
  let(:project) { Dir.mktmpdir("review-project") }

  before do
    allow(Process).to receive(:spawn).and_return(12_345)
    system("git", "init", "-q", project, exception: true)
    FileUtils.mkdir_p(File.join(project, "docs"))
    File.write(File.join(project, "docs", "plan.md"), "# Plan\n")
    File.write(File.join(project, ".env"), "TOKEN=x\n")
    File.write(File.join(project, "key.pem"), "-----BEGIN-----\n")
  end

  after do
    FileUtils.rm_rf(state_dir)
    FileUtils.rm_rf(project)
  end

  def dir_of(id) = Samagotchi::Session.session_dir(id, state_dir: state_dir)

  def note_of(id)
    notes = Samagotchi::SessionInbox.find_new_note_files(dir_of(id)).map { |f| Samagotchi::SessionInbox.read_note(f) }
    expect(notes.size).to eq(1)
    notes.first
  end

  describe ".check_subjects" do
    it "gives project-relative paths, from the session's folder or absolute, without repeats" do
      subdir = File.join(project, "docs")
      expect(described_class.check_subjects(["plan.md", File.join(project, "docs/plan.md")], dir: subdir)).to eq(["docs/plan.md"])
    end

    it "refuses with one message a missing file, a folder, a file outside the project and a secret" do
      outside = Tempfile.create("outside").tap(&:close).path
      [["docs/nope.md", "docs/nope.md"], ["docs", "docs"], [outside, outside], [".env", ".env"],
       ["key.pem", "key.pem"], ["../#{File.basename(project)}/.env", "../#{File.basename(project)}/.env"]].each do |given, named|
        expect { described_class.check_subjects([given], dir: project) }
          .to raise_error(described_class::Refused, format(described_class::SUBJECT_REFUSED, named))
      end
    ensure
      File.unlink(outside) if outside && File.exist?(outside)
    end

    it "refuses a symlink in the project that leads out of it" do
      secret = Dir.mktmpdir("review-secret")
      File.write(File.join(secret, "notes.md"), "x")
      File.symlink(File.join(secret, "notes.md"), File.join(project, "docs", "link.md"))
      expect { described_class.check_subjects(["docs/link.md"], dir: project) }.to raise_error(described_class::Refused)
    ensure
      FileUtils.rm_rf(secret)
    end

    it "refuses more than MAX_SUBJECTS" do
      expect { described_class.check_subjects(["docs/plan.md"] * (described_class::MAX_SUBJECTS + 1), dir: project) }
        .to raise_error(described_class::Refused, /at most/)
    end
  end

  describe ".start" do
    it "starts an idle review session in the folder with its subjects and a note naming them" do
      session = described_class.start(subjects: ["docs/plan.md"], dir: project, model: "main:gemma-small", state_dir: state_dir)
      saved = Samagotchi::Session.load(session.id, state_dir: state_dir)

      expect(saved.review).to eq(Samagotchi::SessionReview.new(subjects: ["docs/plan.md"]))
      expect(saved.toolkit_origin).to eq("chosen")
      expect(saved.status).to eq(Samagotchi::Session::STATUS_IDLE)
      expect(saved.first_preview).to eq("review: docs/plan.md")
      expect(saved.working_directory).to eq(project)
      note = note_of(session.id)
      expect(note[:source]).to eq("review")
      expect(note[:text]).to include("docs/plan.md").and include("read-only review turn")
      expect(JSON.parse(File.read(File.join(state_dir, "#{session.id}.json")))["review"])
        .to eq("subjects" => ["docs/plan.md"])
    end

    it "refuses a review with no subjects, and a secret subject, before anything starts" do
      expect { described_class.start(subjects: [], dir: project, state_dir: state_dir) }
        .to raise_error(described_class::Refused, described_class::NO_SUBJECTS)
      expect { described_class.start(subjects: [".env"], dir: project, state_dir: state_dir) }
        .to raise_error(described_class::Refused, /\.env can't be a review subject/)
      expect(Dir.glob(File.join(state_dir, "*.json"))).to be_empty
    end
  end

  describe ".fork" do
    def working(created: "2026-10-23T09:00:00+02:00")
      Samagotchi::Session.new_session(mode: "assist", model_name: "main:gemma-small", working_directory: project).tap do |s|
        s.messages = [{ role: "user", content: "build it" }, { role: "tool", content: "SECRET OUTPUT" }]
        s.first_preview = "build it"
        s.created_at = created
        s.save(state_dir: state_dir)
      end
    end

    it "seeds a new session with the source's recap and the seed, never its transcript, and leaves the source as it was" do
      source = working
      FileUtils.mkdir_p(dir_of(source.id))
      File.write(File.join(dir_of(source.id), Samagotchi::RecapStore::FILE), JSON.generate(text: "Built P4.", created_at: "2026-10-23T10:00:00Z"))

      session = described_class.fork(from: source.id[0, 8], subjects: ["docs/plan.md"], seed: "HANDOFF TEXT",
                                     state_dir: state_dir, recap_wait: 0)
      saved = Samagotchi::Session.load(session.id, state_dir: state_dir)

      expect(saved.review).to eq(Samagotchi::SessionReview.new(subjects: ["docs/plan.md"], from: source.id))
      expect(saved.toolkit_origin).to eq("chosen")
      expect(saved.continues).to be_nil
      expect(saved.messages).to eq([])
      expect(saved.working_directory).to eq(project)
      expect(saved.first_preview).to eq("review of build it (docs/plan.md)")
      text = note_of(session.id)[:text]
      expect(text).to include("starts from #{source.id[0, 8]}").and include("Built P4.").and include("HANDOFF TEXT")
      expect(text).not_to include("SECRET OUTPUT")
      expect(Samagotchi::ArchiveStore.archived?(dir_of(source.id))).to be(false)
      expect(Samagotchi::SessionChain.next_of(source.id, state_dir: state_dir)).to be_nil
    end

    it "asks the source's live worker for a fresh recap first" do
      source = working
      allow(Samagotchi::SessionContinue).to receive(:recap_before_archive)
      described_class.fork(from: source.id, state_dir: state_dir, recap_wait: 7)
      expect(Samagotchi::SessionContinue).to have_received(:recap_before_archive).with(source.id, state_dir, wait: 7)
    end

    it "refuses an unknown session and a subject outside the source's project" do
      expect { described_class.fork(from: "00000000-0000-4000-8000-000000000000", state_dir: state_dir, recap_wait: 0) }
        .to raise_error(ArgumentError)
      source = working
      expect { described_class.fork(from: source.id, subjects: [".env"], state_dir: state_dir, recap_wait: 0) }
        .to raise_error(described_class::Refused)
    end
  end

  it "warns that a working session's participant turns act in it, and says so while an older worker reads only" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "main:gemma-small", working_directory: project)
    id = session.id[0, 8]
    expect(Samagotchi::ParticipantMode).to receive(:live).with(session, state_dir: state_dir).at_least(:once).and_call_original
    expect(described_class.share_warning(session, state_dir: state_dir))
      .to eq("#{id} is a working session: a participant's turns act in it with this session's tools (writes " \
             "included; asks come to you) and read what its history holds (0 tool outputs so far). A review session " \
             "only reads.")

    sidecar = Samagotchi::WorkerSidecar.new(port: 1, session_id: session.id, features: %w[delivery review_turns])
    allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(Samagotchi::WorkerLink::Live.new(sidecar: sidecar))
    expect(described_class.share_warning(session, state_dir: state_dir))
      .to eq(format(described_class::OLDER_WORKER_WARNING, id: id, outputs: "0 tool outputs so far"))
    terms = described_class.share_terms(session, state_dir: state_dir)
    expect(terms.warning).to include("a participant invited now only reads").and include("invite them again")
    expect([terms.grant_mode, terms.mode]).to eq([nil, :review])
  end

  it "stamps an invite pair only with the warning that their turns act" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "main:gemma-small", working_directory: project)
    terms = described_class.share_terms(session, state_dir: state_dir)
    expect([terms.grant_mode, terms.mode]).to eq(["pair", :pair])
    expect(terms.warning).to start_with("#{session.id[0, 8]} is a working session: a participant's turns act")
    session.review = { subjects: ["docs/plan.md"] }
    expect(described_class.share_terms(session, state_dir: state_dir).to_h).to eq(grant_mode: nil, mode: :review, warning: nil)
  end

  it "has no warning for a review session" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "main:gemma-small", working_directory: project)
    session.review = { subjects: ["docs/plan.md"] }
    expect(described_class.share_warning(session, state_dir: state_dir)).to be_nil
  end

  it "keeps a review session's field across a continue" do
    session = described_class.start(subjects: ["docs/plan.md"], dir: project, model: "main:gemma-small", state_dir: state_dir)
    link = Samagotchi::SessionContinue.run(session.id, state_dir: state_dir, recap_wait: 0, archive_wait: 0)
    continued = Samagotchi::Session.load(link.id, state_dir: state_dir)
    expect(continued.review.subjects).to eq(["docs/plan.md"])
    expect(continued.toolkit_origin).to eq("inherited")
  end
end
