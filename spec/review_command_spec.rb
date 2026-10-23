# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/review_command"
require "samagotchi/session_manager"
require_relative "support/remote_backend"

# chi review: a review session for files, or a review fork of a session,
# here and through chi --remote (the remote's chi web checks the files).
RSpec.describe Samagotchi::ReviewCommand do
  let(:state_dir) { Dir.mktmpdir("review-command") }
  let(:project) { Dir.mktmpdir("review-command-project") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  before do
    allow(Process).to receive(:spawn).and_return(12_345)
    system("git", "init", "-q", project, exception: true)
    FileUtils.mkdir_p(File.join(project, "docs"))
    File.write(File.join(project, "docs", "plan.md"), "# Plan\n")
    File.write(File.join(project, ".env"), "TOKEN=x\n")
  end

  after do
    FileUtils.rm_rf(state_dir)
    FileUtils.rm_rf(project)
  end

  def sessions = Dir.glob(File.join(state_dir, "*.json")).map { |f| JSON.parse(File.read(f)) }

  it "prints its usage with no arguments" do
    expect(described_class.new([], stdout: out, stderr: err, state_dir: state_dir).run).to eq(0)
    expect(out.string).to start_with("Usage: chi review FILE…")
  end

  RemoteBackend.both(self) do
    def review(*argv) = described_class.new(argv, stdout: out, stderr: err, state_dir: state_dir, access: backend_access(state_dir)).run

    it "starts an idle review session for the files and prints how to open it and invite someone" do
      expect(review("docs/plan.md", "--dir", project, "--model", "main:gemma-small")).to eq(0), err.string

      saved = sessions.find { |s| s["review"] }
      short = saved["id"][0, 8]
      expect(saved["review"]).to eq("subjects" => ["docs/plan.md"])
      expect(saved["status"]).to eq("idle")
      expect(out.string.lines).to eq(["#{saved["id"]}  review · docs/plan.md · idle\n",
                                      "open it: #{via.open_it(short)}\n",
                                      "invite someone: #{via.command("share #{short} --name NAME")}\n"])
    end

    it "refuses a secret or missing subject with one line, exit 1, and starts nothing" do
      [".env", "docs/nope.md"].each do |file|
        err.truncate(0)
        err.rewind
        expect(review(file, "--dir", project)).to eq(1)
        expect(err.string).to eq("chi review: #{format(Samagotchi::ReviewStart::SUBJECT_REFUSED, file)}\n")
      end
      expect(sessions).to be_empty
    end

    it "--from starts a review fork of a session in its folder, which keeps running unarchived" do
      source = Samagotchi::Session.new_session(mode: "assist", model_name: "main:gemma-small", working_directory: project)
      source.first_preview = "build it"
      source.save(state_dir: state_dir)

      expect(review("--from", source.id[0, 8], "docs/plan.md")).to eq(0), err.string
      fork = sessions.find { |s| s["review"] }
      expect(fork["review"]).to eq("subjects" => ["docs/plan.md"], "from" => source.id)
      expect(fork["working_directory"]).to eq(source.working_directory)
      expect(out.string.lines.first).to eq("#{fork["id"]}  a review of #{source.id[0, 8]} · docs/plan.md · idle\n")
      expect(Samagotchi::ArchiveStore.archived?(Samagotchi::Session.session_dir(source.id, state_dir: state_dir))).to be(false)
    end

    it "is a usage error with neither files nor --from, and with --dir beside --from" do
      expect(review("--model", "x")).to eq(2)
      expect(err.string).to include("give the files to review, or --from ID")
      expect(review("--from", "abcd", "--dir", project)).to eq(2)
      expect(err.string).to include("--dir goes with files, not --from")
    end
  end

  it "needs --dir as an absolute path under a remote" do
    access = RemoteBackend.access(state_dir: state_dir)
    expect(described_class.new(["docs/plan.md"], stdout: out, stderr: err, access: access).run).to eq(2)
    expect(err.string).to include("--dir DIR: the folder on studio")
  end
end
