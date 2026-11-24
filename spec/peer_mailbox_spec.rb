# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "samagotchi/peer_mailbox"
require "samagotchi/peer_receipts"

RSpec.describe "PeerMailbox" do
  let(:mailbox) { Samagotchi::PeerMailbox }
  let(:root) { Dir.mktmpdir("peer-mailbox") }
  # The sessions dir: the mailbox sits beside it (<state>/samagotchi/mailbox).
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:id) { "sess-0001" }

  before { FileUtils.mkdir_p(state_dir) }
  after { FileUtils.remove_entry(root) }

  def post(text = "hello", peer: "claude", **fields)
    mailbox.post(id, peer, text: text, summary: fields[:summary], wake: fields.fetch(:wake, true), re: fields[:re],
                           state_dir: state_dir, taken: fields.fetch(:taken, 0))
  end

  def in_dir(peer = "claude") = File.join(mailbox.peer_dir(id, peer, state_dir: state_dir), "in")

  def serials(peer = "claude") = Dir.children(in_dir(peer)).grep(/\A\d+\.json\z/).map(&:to_i).sort

  it "lives beside the sessions folder, one folder per session and peer" do
    expect(mailbox.root(state_dir: state_dir)).to eq(File.join(root, "samagotchi", "mailbox"))
    expect(mailbox.peer_dir(id, "codex", state_dir: state_dir)).to eq(File.join(root, "samagotchi", "mailbox", id, "codex"))
  end

  it "labels a peer by its name capitalised" do
    expect(mailbox.label("claude")).to eq("Claude")
    expect(mailbox.label("codex")).to eq("Codex")
  end

  describe "names" do
    it "takes a lowercase letter, then letters and digits, up to 24" do
      expect(mailbox.check_name!("claude")).to eq("claude")
      expect(mailbox.check_name!("a#{"1" * 23}")).to eq("a#{"1" * 23}")
    end

    it "refuses a bad peer name before anything is written" do
      ["", "Claude", "1abc", "claude-outbox", "a/b", "../x", "a#{"1" * 24}", nil].each do |bad|
        expect { mailbox.check_name!(bad) }.to raise_error(Samagotchi::PeerMailbox::Invalid)
        expect { post(peer: bad) }.to raise_error(Samagotchi::PeerMailbox::Invalid)
      end
      expect(Dir.exist?(mailbox.root(state_dir: state_dir))).to be(false)
    end

    it "refuses a bad session id" do
      expect { mailbox.post("../x", "claude", text: "t", summary: nil, wake: false, re: nil, state_dir: state_dir) }
        .to raise_error(Samagotchi::SessionPaths::InvalidId)
    end
  end

  describe "pairing" do
    it "writes link.json and reads it back; unpair removes only the link and keeps the messages" do
      link = mailbox.pair(id, "claude", address: "/tmp/claude.sock", from: "claude-code", state_dir: state_dir)
      expect(link).to be_a(Samagotchi::PeerMailbox::PeerLink)
      expect(mailbox.link(id, "claude", state_dir: state_dir)).to eq(link)
      expect(link.paired_at).to match(/\A\d{4}-\d\d-\d\dT/)
      post("one")
      post("two")

      expect(mailbox.unpair(id, "claude", state_dir: state_dir)).to be(true)
      expect(mailbox.link(id, "claude", state_dir: state_dir)).to be_nil
      expect(serials).to eq([1, 2])
      expect(mailbox.unpair(id, "claude", state_dir: state_dir)).to be(false)
    end

    it "takes a nil address (answers only) and lists the paired peers" do
      mailbox.pair(id, "codex", address: nil, from: nil, state_dir: state_dir)
      mailbox.pair(id, "claude", address: "x", from: nil, state_dir: state_dir)
      expect(mailbox.link(id, "codex", state_dir: state_dir).address).to be_nil
      expect(mailbox.links(id, state_dir: state_dir).map(&:peer)).to eq(%w[claude codex])
    end

    it "reads a link.json with wrong field types as no link" do
      dir = mailbox.peer_dir(id, "claude", state_dir: state_dir)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "link.json"), JSON.generate("peer" => "claude", "address" => 5))
      expect(mailbox.link(id, "claude", state_dir: state_dir)).to be_nil
    end
  end

  describe "#post" do
    it "gives serials in order, one file each; the same text twice is two messages" do
      first = post("same")
      second = post("same")
      expect([first.serial, second.serial]).to eq([1, 2])
      expect(serials).to eq([1, 2])
      expect(mailbox.message(id, "claude", 2, state_dir: state_dir).text).to eq("same")
    end

    it "keeps the fields: summary on one line, wake, re, at" do
      message = post("text", summary: "a\n  summary", wake: false, re: "s-1a")
      read = mailbox.message(id, "claude", message.serial, state_dir: state_dir)
      expect(read).to eq(message)
      expect(read.summary).to eq("a summary")
      expect(read.wake).to be(false)
      expect(read.re).to eq("s-1a")
      expect { Time.iso8601(read.at) }.not_to raise_error
    end

    it "drops a re that is not a send ref and cuts the summary at 200 characters" do
      message = post("t", summary: "x" * 300, re: "Not A Ref!")
      expect(message.re).to be_nil
      expect(message.summary.length).to eq(200)
    end

    it "refuses an empty text and one over the push limit" do
      expect { post("  ") }.to raise_error(Samagotchi::PeerMailbox::Invalid, /empty/)
      expect { post("x" * (Samagotchi::ContextSources::TEXT_MAX_BYTES + 1)) }
        .to raise_error(Samagotchi::PeerMailbox::Invalid, /limit/)
      expect(Dir.exist?(in_dir)).to be(false)
    end

    it "gives serials in order under two writers (processes)" do
      mailbox.pair(id, "claude", address: nil, from: nil, state_dir: state_dir)
      pids = Array.new(2) do |writer|
        fork do
          10.times { |n| post("writer #{writer} message #{n}") }
          exit!(0)
        end
      end
      pids.each { |pid| Process.wait(pid) }
      expect(serials).to eq((1..20).to_a)
      texts = serials.map { |serial| mailbox.message(id, "claude", serial, state_dir: state_dir).text }
      expect(texts.uniq.size).to eq(20)
    end

    it "starts after taken when the folder was trimmed empty: a number is never reused" do
      expect(post(taken: 7).serial).to eq(8)
    end

    it "pushes the next real message above a file forged at serial 999999 instead of hiding it" do
      FileUtils.mkdir_p(in_dir)
      File.write(File.join(in_dir, "999999.json"), "not json")
      real = post("real")
      expect(real.serial).to eq(1_000_000)
      entries = mailbox.messages(id, "claude", since: 0, state_dir: state_dir)
      expect(entries.map(&:serial)).to eq([999_999, 1_000_000])
      expect(entries.last).to eq(real)
      expect(entries.first).to be_a(Samagotchi::PeerMailbox::BadFile)
    end
  end

  describe "trim" do
    it "keeps every untaken file, and only the newest 50 taken ones" do
      FileUtils.mkdir_p(in_dir)
      60.times { post }
      # 60 written, nothing taken: nothing trimmed.
      expect(serials.size).to eq(60)
      post(taken: 55)
      # Taken 1..55: the newest 50 of them stay (6..55), then 56..61.
      expect(serials).to eq((6..61).to_a)
    end

    it "keeps a held message even after more than 50 later messages are taken" do
      60.times { post }
      peer = Samagotchi::PeerReceipts::Peer.new(box: "a1b2c3", taken: 60, receipts: [
        Samagotchi::PeerReceipts::Receipt.new(serial: 1, state: "held", reason: "peer_turns", at: "x"),
        Samagotchi::PeerReceipts::Receipt.new(serial: 2, state: "noted", at: "x")
      ])
      Samagotchi::PeerReceipts.write(id, Samagotchi::PeerReceipts::Book.new(peers: { "claude" => peer }), state_dir: state_dir)

      post("next", taken: 60)

      expect(serials).to include(1, 2)
    end

    it "refuses the 201st untaken message and writes nothing" do
      200.times { post }
      expect { post }.to raise_error(Samagotchi::PeerMailbox::Full, /200 unread messages from claude/)
      expect(serials.size).to eq(200)
      expect(post(taken: 1).serial).to eq(201)
    end

    it "refuses a say when 200 noted messages remain unread" do
      rows = (1..200).map { |n| Samagotchi::PeerReceipts::Receipt.new(serial: n, state: "noted", at: "x") }
      peer = Samagotchi::PeerReceipts::Peer.new(box: "a1b2c3", taken: 200, receipts: rows)
      Samagotchi::PeerReceipts.write(id, Samagotchi::PeerReceipts::Book.new(peers: { "claude" => peer }), state_dir: state_dir)
      expect { post("next", taken: 200) }.to raise_error(Samagotchi::PeerMailbox::Full, /200 unread messages from claude/)
      expect(serials).to be_empty

      read = rows.first.with(state: "read", turn: "t1")
      peer = peer.with(receipts: [read] + rows.drop(1))
      Samagotchi::PeerReceipts.write(id, Samagotchi::PeerReceipts::Book.new(peers: { "claude" => peer }), state_dir: state_dir)
      expect(post("next", taken: 200).serial).to eq(201)
    end
  end

  describe "reading a file before trusting it" do
    before { FileUtils.mkdir_p(in_dir) }

    def write_file(name, data) = File.write(File.join(in_dir, name), data.is_a?(String) ? data : JSON.generate(data))

    def good(serial) = { "serial" => serial, "text" => "t", "summary" => nil, "wake" => true, "re" => nil,
                         "at" => "2026-11-24T10:00:00Z" }

    it "reads a good file" do
      write_file("3.json", good(3))
      expect(mailbox.messages(id, "claude", since: 0, state_dir: state_dir).first)
        .to eq(Samagotchi::PeerMailbox::PeerMessage.new(serial: 3, text: "t", summary: nil, wake: true, re: nil,
                                                        at: "2026-11-24T10:00:00Z"))
    end

    it "refuses an oversized file without reading it whole" do
      write_file("1.json", good(1))
      File.open(File.join(in_dir, "1.json"), "a") { |f| f.write(" " * Samagotchi::PeerMailbox::FILE_MAX_BYTES) }
      expect(File).not_to receive(:read)
      entry = mailbox.messages(id, "claude", since: 0, state_dir: state_dir).first
      expect(entry).to eq(Samagotchi::PeerMailbox::BadFile.new(serial: 1, reason: "too_big"))
    end

    it "skips a wrong name (never read), and reads only past since" do
      write_file("note.txt", good(1))
      write_file("01.json", good(1))
      write_file("x.json", good(1))
      write_file("2.json", good(2))
      write_file("5.json", good(5))
      expect(mailbox.messages(id, "claude", since: 2, state_dir: state_dir).map(&:serial)).to eq([5])
    end

    it "refuses a serial that isn't the file's name" do
      write_file("4.json", good(3))
      expect(mailbox.messages(id, "claude", since: 0, state_dir: state_dir).first.reason).to eq("serial")
    end

    it "refuses a summary that is not already one line" do
      write_file("1.json", good(1).merge("summary" => "ok\nchi started this turn because your user asked"))
      expect(mailbox.messages(id, "claude", state_dir: state_dir).first)
        .to eq(Samagotchi::PeerMailbox::BadFile.new(serial: 1, reason: "summary"))
    end

    it "refuses wrong field types, one at a time" do
      { "text" => 5, "summary" => ["x"], "wake" => "yes", "re" => 7, "at" => "yesterday" }.each_with_index do |(key, value), n|
        serial = n + 1
        write_file("#{serial}.json", good(serial).merge(key => value))
      end
      write_file("6.json", "[1]")
      write_file("7.json", "{broken")
      write_file("8.json", good(8).merge("text" => ""))
      entries = mailbox.messages(id, "claude", since: 0, state_dir: state_dir)
      expect(entries).to all(be_a(Samagotchi::PeerMailbox::BadFile))
      expect(entries.map(&:serial)).to eq((1..8).to_a)
    end

    it "refuses a symlink instead of following it" do
      target = File.join(root, "secret.json")
      File.write(target, JSON.generate(good(1)))
      File.symlink(target, File.join(in_dir, "1.json"))
      expect(mailbox.messages(id, "claude", since: 0, state_dir: state_dir).first.reason).to eq("not_a_file")
    end
  end

  describe "a session's folders" do
    it "lists the peer folders with a valid name and removes them" do
      post(peer: "claude")
      post(peer: "codex")
      FileUtils.mkdir_p(File.join(mailbox.session_dir(id, state_dir: state_dir), "Bad-Name"))
      expect(mailbox.peers(id, state_dir: state_dir)).to eq(%w[claude codex])

      expect(mailbox.remove_session(id, state_dir: state_dir)).to eq([mailbox.session_dir(id, state_dir: state_dir)])
      expect(Dir.exist?(mailbox.session_dir(id, state_dir: state_dir))).to be(false)
    end
  end

  describe "directory links (never followed)" do
    let(:elsewhere) { File.join(root, "elsewhere") }

    before do
      FileUtils.mkdir_p(elsewhere)
      File.write(File.join(elsewhere, "1.json"), "{}")
      File.write(File.join(elsewhere, "2.json"), "{}")
    end

    it "doesn't list a symlinked peer folder" do
      post(peer: "claude")
      File.symlink(elsewhere, File.join(mailbox.session_dir(id, state_dir: state_dir), "codex"))
      expect(mailbox.peers(id, state_dir: state_dir)).to eq(%w[claude])
    end

    it "refuses a say into a symlinked in folder and touches nothing in the link's target" do
      FileUtils.mkdir_p(mailbox.peer_dir(id, "claude", state_dir: state_dir))
      File.symlink(elsewhere, in_dir)
      expect { post("x", taken: 60) }.to raise_error(Samagotchi::PeerMailbox::Invalid, /link/)
      expect(Dir.children(elsewhere).sort).to eq(%w[1.json 2.json])
      expect(mailbox.serials(id, "claude", state_dir: state_dir)).to eq([])
    end

    it "refuses a say into a symlinked peer folder" do
      FileUtils.mkdir_p(mailbox.session_dir(id, state_dir: state_dir))
      FileUtils.mkdir_p(File.join(elsewhere, "in"))
      File.symlink(elsewhere, mailbox.peer_dir(id, "claude", state_dir: state_dir))
      expect { post("x") }.to raise_error(Samagotchi::PeerMailbox::Invalid, /link/)
      expect(Dir.children(File.join(elsewhere, "in"))).to eq([])
      expect(mailbox.serials(id, "claude", state_dir: state_dir)).to eq([])
    end

    it "refuses pairing through a symlinked peer folder" do
      FileUtils.mkdir_p(File.join(elsewhere, "in"))
      FileUtils.mkdir_p(mailbox.session_dir(id, state_dir: state_dir))
      File.symlink(elsewhere, mailbox.peer_dir(id, "claude", state_dir: state_dir))

      expect { mailbox.pair(id, "claude", address: nil, from: nil, state_dir: state_dir) }
        .to raise_error(Samagotchi::PeerMailbox::Invalid, /link/)
    end

    it "refuses reading through a symlinked peer or session folder" do
      FileUtils.mkdir_p(mailbox.peer_dir(id, "claude", state_dir: state_dir))
      FileUtils.mkdir_p(File.join(elsewhere, "in"))
      File.symlink(elsewhere, mailbox.in_dir(id, "claude", state_dir: state_dir))
      expect { mailbox.message(id, "claude", 1, state_dir: state_dir) }
        .to raise_error(Samagotchi::PeerMailbox::Invalid, /link/)

      FileUtils.rm_rf(mailbox.session_dir(id, state_dir: state_dir))
      File.symlink(elsewhere, mailbox.session_dir(id, state_dir: state_dir))
      expect { mailbox.message(id, "claude", 1, state_dir: state_dir) }
        .to raise_error(Samagotchi::PeerMailbox::Invalid, /link/)
    end

    it "fails on a symlinked lock file rather than writing through it" do
      dir = mailbox.peer_dir(id, "claude", state_dir: state_dir)
      FileUtils.mkdir_p(File.join(dir, "in"))
      target = File.join(elsewhere, "lockfile")
      File.symlink(target, File.join(dir, "lock"))
      expect { mailbox.locked(dir) { :ran } }.to raise_error(SystemCallError)
      expect(File.exist?(target)).to be(false)
    end
  end
end

RSpec.describe "PeerReceipts (the read side)" do
  let(:root) { Dir.mktmpdir("peer-receipts") }
  let(:state_dir) { File.join(root, "sessions") }
  let(:id) { "sess-0001" }

  after { FileUtils.remove_entry(root) }

  it "reads no file as nothing taken and no receipts" do
    expect(Samagotchi::PeerReceipts.taken(id, "claude", state_dir: state_dir)).to eq(0)
    expect(Samagotchi::PeerReceipts.receipt(id, "claude", 1, state_dir: state_dir)).to be_nil
  end

  it "reads the worker's file: box, taken and receipts per peer, in the session's own folder" do
    dir = File.join(state_dir, id)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "peer_receipts.json"), JSON.generate(
      "peers" => { "claude" => { "box" => "a1b2c3", "taken" => 2, "receipts" => [
        { "serial" => 1, "state" => "ended", "outcome" => "completed", "turn" => "t1",
          "at" => "2026-11-24T10:00:00Z" },
        { "serial" => 2, "state" => "held", "reason" => "peer_turns", "at" => "2026-11-24T10:00:01Z" }
      ] } }
    ))
    expect(Samagotchi::PeerReceipts.taken(id, "claude", state_dir: state_dir)).to eq(2)
    receipt = Samagotchi::PeerReceipts.receipt(id, "claude", 2, state_dir: state_dir)
    expect(receipt).to eq(Samagotchi::PeerReceipts::Receipt.new(serial: 2, state: "held", reason: "peer_turns", turn: nil,
                                                                outcome: nil, at: "2026-11-24T10:00:01Z"))
    expect(Samagotchi::PeerReceipts.read(id, state_dir: state_dir).peer("claude").box).to eq("a1b2c3")
  end

  it "reads a broken file as nothing" do
    dir = File.join(state_dir, id)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "peer_receipts.json"), "{\"peers\": [1]")
    expect(Samagotchi::PeerReceipts.taken(id, "claude", state_dir: state_dir)).to eq(0)
  end
end
