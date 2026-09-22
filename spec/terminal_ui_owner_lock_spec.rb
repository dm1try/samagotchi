# frozen_string_literal: true

require "tmpdir"
require "samagotchi/terminal_ui"

# The in-process TUI runs its own Engine, so it owns its session like a worker
# does: a session a worker owns can't be resumed here, and while the TUI runs
# its session no worker can take it.
RSpec.describe "TerminalUI session ownership" do
  let(:state_home) { Dir.mktmpdir("tui-owner-state") }
  let(:client) { instance_double(Samagotchi::Client) }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "gemma4"
    ENV["XDG_STATE_HOME"] = state_home
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(state_home)
  end

  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd).tap(&:save)
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id) }

  it "refuses to resume a session a worker owns, before loading it" do
    lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
    expect(Samagotchi::Session).not_to receive(:load)

    expect { Samagotchi::TerminalUI.new(client: client, session_id: session.id) }
      .to raise_error(Samagotchi::TerminalUI::SessionBusy, /chi web.*pid #{Process.pid}/)
  ensure
    lock&.release
  end

  it "owns a resumed session for as long as it lives" do
    ui = Samagotchi::TerminalUI.new(client: client, session_id: session.id)

    expect(Samagotchi::OwnerLock.owner(session_dir)).to include("kind" => "tui", "pid" => Process.pid)
    expect(Samagotchi::OwnerLock.acquire(session_dir, kind: "worker", wait: 0)).to be_nil
    expect(ui).to be_a(Samagotchi::TerminalUI)
  end
end
