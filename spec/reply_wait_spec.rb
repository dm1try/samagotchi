# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/reply_wait"
require "samagotchi/session_manager"

# A session's next reply: an output/ file past the caller's cursor, or the
# reason none will come.
RSpec.describe Samagotchi::ReplyWait do
  let(:tmpdir) { Dir.mktmpdir("reply-wait") }
  let(:session) { make(status: "running") }
  let(:threads) { [] }

  after do
    threads.each(&:join)
    FileUtils.rm_rf(tmpdir)
  end

  def make(status:)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w").tap do |s|
      s.status = status
      s.save(state_dir: tmpdir)
    end
  end

  def set(status: nil, pending_question: :keep, last_prompt: nil)
    s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
    s.status = status if status
    s.pending_question = pending_question unless pending_question == :keep
    s.last_prompt = last_prompt if last_prompt
    s.save(state_dir: tmpdir)
  end

  def write_reply(text)
    Samagotchi::SessionManager.write_output(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), text)
    sleep(0.002)
  end

  def later(delay = 0.1, &block)
    threads << Thread.new do
      sleep(delay)
      block.call
    end
  end

  def wait(cursor: nil, timeout: 5, **opts)
    described_class.call(session.id, state_dir: tmpdir, cursor: cursor, timeout: timeout, poll_interval: 0.02, **opts)
  end

  it "returns a reply file past the cursor, with its name as the next cursor" do
    write_reply("old")
    cursor = described_class.newest_reply(session.id, state_dir: tmpdir)
    later { write_reply("new") }

    result = wait(cursor: cursor)
    expect(result.status).to eq(:done)
    expect(result.text).to eq("new")
    expect(result.file).to be > cursor
  end

  it "takes any reply with no cursor" do
    write_reply("there already")
    expect(wait.text).to eq("there already")
  end

  it "ends without a reply when the session ran and went idle" do
    later { set(status: "idle") }
    expect(wait.status).to eq(:no_reply)
  end

  it "keeps waiting on a session it never saw running (a message not picked up yet)" do
    set(status: "idle")
    later do
      set(status: "running")
      sleep(0.1)
      write_reply("late")
      set(status: "idle")
    end
    expect(wait.text).to eq("late")
  end

  it "returns a pending question" do
    set(pending_question: { id: "q1", kind: "approval", question: "Run rm?" })
    result = wait
    expect(result.status).to eq(:waiting_for_answer)
    expect(result.question).to include(id: "q1", kind: "approval")
  end

  it "returns a failed or stopped worker" do
    set(status: "error", last_prompt: "boom ")
    expect(wait).to have_attributes(status: :error, text: "boom")

    set(status: "stopped")
    expect(wait.status).to eq(:stopped)
  end

  it "stops when cancelled" do
    flag = [false]
    later { flag[0] = true }
    expect(wait(cancelled: -> { flag[0] }).status).to eq(:canceled)
  end

  it "times out, and waits with no limit on nil" do
    expect(wait(timeout: 0).status).to eq(:timeout)

    later(0.3) { write_reply("eventually") }
    expect(wait(timeout: nil).text).to eq("eventually")
  end

  it "raises for a missing session" do
    expect { described_class.call("nope", state_dir: tmpdir, cursor: nil) }.to raise_error(ArgumentError)
  end
end
