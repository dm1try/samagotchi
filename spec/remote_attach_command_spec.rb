# frozen_string_literal: true

require "stringio"
require "spec_helper"
require "samagotchi/remote_attach_command"

# chi --remote NAME --attach ID | --resume ID | --dir DIR [-p TEXT]: the
# parsed run flags into a remote attach (the launcher a double; the attach
# itself is the loop's and RemoteLink's specs).
RSpec.describe Samagotchi::RemoteAttachCommand do
  let(:err) { StringIO.new }
  let(:remote) { instance_double(Samagotchi::SessionAccess::Remote, name: "studio", require_feature!: nil) }
  let(:launcher) { class_double(Samagotchi::TerminalUI::AttachLauncher, run: :detached, exit_status: 0) }
  let(:connector) { class_double(Samagotchi::TerminalUI::RemoteConnector, client_id: "tui:9@mac") }

  before do
    allow(connector).to receive(:new) { |_remote, session_id:| [:connector, session_id] }
    allow(launcher).to receive(:exit_status) { |ended| Samagotchi::TerminalUI::AttachLauncher.exit_status(ended) }
    allow(launcher).to receive(:warn_memory_flags_ignored) do |*args, **opts|
      Samagotchi::TerminalUI::AttachLauncher.warn_memory_flags_ignored(*args, **opts)
    end
  end

  def run(**options) = described_class.new(options, access: remote, stderr: err, launcher: launcher, connector: connector).run

  it "attaches to a session there: resolved there, the first commands for its worker, the connector for it" do
    allow(remote).to receive(:resolve).with("ab").and_return("ab12")

    expect(run(attach: "ab", prompt: "go", model: "m", thinking: "low", llm_context: { strategy: "forget" },
               no_interrupt: true, no_default_input: true)).to eq(0)

    expect(remote).to have_received(:require_feature!).with("remote_attach")
    expect(launcher).to have_received(:run)
      .with(attach: "ab12", resume: nil, prompt: "go", model: "m", no_interrupt: true, default_input: false,
            llm_context: { strategy: "forget" }, thinking: "low", connector: [:connector, "ab12"])
    expect(err.string).to eq("")
  end

  it "says which setup flags an existing session ignores, --dir among them" do
    allow(remote).to receive(:resolve).and_return("ab12")
    run(resume: "ab", dir: "/x", toolkit: "lean", sets: ["a=b"])
    expect(err.string).to eq("(--dir, --toolkit and --set apply to a new session; ab12 keeps its own)\n")
    expect(launcher).to have_received(:run).with(hash_including(resume: "ab12", attach: nil))
  end

  it "starts a new session there, idle, in --dir with the setup flags as typed, and its -p once attached" do
    created = Samagotchi::SessionAccess::Created.new(id: "new1", model_warning: "no such model there", continues: nil,
                                                     moved_children: [], parent_answers_warning: "capped to standard")
    allow(remote).to receive(:create).and_return(created)

    expect(run(dir: "/Users/me/app", prompt: "hi", model: "m", thinking: "high", toolkit: "lean", tools: ["x"],
               sets: ["cost-cap.cap=3"], parent_answers: "soft")).to eq(0)

    expect(remote).to have_received(:create) do |spec|
      expect(spec).to have_attributes(prompt: nil, idle: true, working_directory: "/Users/me/app", model_name: "m",
                                      client_id: "tui:9@mac")
      expect(spec.setup).to have_attributes(thinking: "high", toolkit: "lean", tools: ["x"],
                                            settings: { "cost-cap.cap" => "3" }, parent_answers: "soft")
    end
    expect(launcher).to have_received(:run)
      .with(hash_including(attach: nil, resume: nil, prompt: "hi", model: nil, thinking: nil, llm_context: {},
                           connector: [:connector, "new1"]))
    expect(err.string).to eq("chi: warning: no such model there\nchi: warning: --parent-answers capped to standard\n")
  end

  it "needs --dir, an absolute path there, for a new session (exit 2, nothing asked)" do
    allow(remote).to receive(:create)
    words = "Error: a new session on studio needs --dir, that machine's absolute path (or --attach ID / --resume ID)\n"
    expect(run(prompt: "hi")).to eq(2)
    expect(run(dir: "app")).to eq(2)
    expect(err.string).to eq(words * 2)
    expect(remote).not_to have_received(:require_feature!)
    expect(remote).not_to have_received(:create)
  end

  it "refuses conflicting flags in chi --attach's words (exit 1)" do
    expect(run(attach: "a", resume: "b")).to eq(1)
    expect(run(attach: "a", shared: true)).to eq(1)
    expect(err.string).to eq("Error: --attach takes the session id; --resume goes with --shared\n" \
                             "Error: use either --attach ID or --shared\n")
  end

  it "fails a launch in the words it failed with: too old, ambiguous, not found, refused there (exit 1); a bad flag there exits 2" do
    entry = Samagotchi::Remotes::Entry.new(name: "studio", url: "http://192.0.2.10:4567", token: nil)
    too_old = Samagotchi::SessionAccess::Remote.too_old_message(entry, "0.1.0")
    allow(remote).to receive(:require_feature!).and_raise(Samagotchi::SessionAccess::RemoteTooOld, too_old)
    expect(run(attach: "ab")).to eq(1)

    allow(remote).to receive(:require_feature!)
    allow(remote).to receive(:resolve).and_raise(Samagotchi::Session::AmbiguousId.new("ab matches several sessions", ids: %w[ab1 ab2]))
    expect(run(attach: "ab")).to eq(1)

    allow(remote).to receive(:resolve).and_return("ab12")
    allow(launcher).to receive(:run).and_raise(Samagotchi::TerminalUI::AttachLauncher::Error, "session ab12 is open in a chi REPL; close it there first")
    expect(run(attach: "ab")).to eq(1)

    allow(remote).to receive(:create).and_raise(Samagotchi::SessionAccess::BadRequest.new("unknown toolkit nope", code: "invalid_toolkit"))
    expect(run(dir: "/x", toolkit: "nope")).to eq(2)

    expect(err.string.lines).to eq(["Error: #{too_old}\n", "Error: ab matches several sessions\n",
                                    "Error: session ab12 is open in a chi REPL; close it there first\n",
                                    "Error: unknown toolkit nope\n"])
  end

  it "exits 130, quietly, on a Ctrl-C before the TUI runs (a wait for a leaving worker there)" do
    allow(remote).to receive(:resolve).and_return("ab12")
    allow(launcher).to receive(:run).and_raise(Interrupt)

    expect(run(attach: "ab")).to eq(130)
    expect(err.string).to eq("")
  end

  it "maps the end of the attach to chi's exit status: 3 for a question left waiting" do
    allow(remote).to receive(:resolve).and_return("ab12")
    allow(launcher).to receive(:run).and_return(:unanswered)
    expect(run(attach: "ab")).to eq(3)
  end
end
