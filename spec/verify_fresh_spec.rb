# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "samagotchi/verify_fresh"
require "samagotchi/session_manager"
require "samagotchi/analytics_file"
require "samagotchi/child_reports"
require "samagotchi/tools/delegate"

RSpec.describe Samagotchi::VerifyFresh do
  let(:root) { Dir.mktmpdir("verify-fresh") }
  let(:state_dir) { File.join(root, "sessions") }
  # A folder outside git: the child starts in it as it is (no worktree).
  let(:folder) { File.join(root, "notes").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:source_turn) { "11111111-2222-3333-4444-555555555555" }
  let(:check_turn) { "22222222-3333-4444-5555-666666666666" }
  let(:anchor) { { turn_id: source_turn, quote: "the cache key\nignores the model" } }
  let(:unclear) do
    { anchor: anchor, verdict: "unclear", reason: "context doesn't say", by: "p:alex", check_turn_id: check_turn,
      at: "2026-10-27T10:00:00.000Z" }
  end
  let(:parent) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: folder).tap do |s|
      s.messages << { role: "user", content: "the whole audit, never the child's", turn_id: source_turn }
      s.verdicts = [unclear]
      s.save(state_dir: state_dir)
    end
  end
  let(:spawned) { [] }
  let(:spawn) do
    lambda do |**options|
      spawned << options
      Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: options[:working_directory],
                                      parent_id: options[:parent_id], delegate: true).tap do |child|
        child.verify_fresh = options[:verify_fresh]
        child.status = Samagotchi::Session::STATUS_RUNNING
        child.save(state_dir: state_dir)
      end
    end
  end

  after { FileUtils.remove_entry(root) }

  def start(of: check_turn, author: "p:alex", mode: :pair)
    described_class.start(parent.id, of: of, author: author, mode: mode, state_dir: state_dir, spawn: spawn)
  end

  describe ".start" do
    it "spawns a delegate child in the parent's own folder whose first prompt is only the claim and the ask" do
      child = start

      options = spawned.first
      expect(options).to include(working_directory: folder, parent_id: parent.id, delegate: true, model_name: "m",
                                 memories: ["system/delegated"])
      expect(options[:prompt]).to eq("Claim:\n> the cache key\n> ignores the model\n\n#{described_class::ASK}")
      expect(options[:prompt]).not_to include("audit")
      expect(options[:verify_fresh].to_file).to eq("author" => "p:alex", "mode" => "pair", "of" => check_turn,
                                                   "anchor" => { "turn_id" => source_turn, "quote" => anchor[:quote] })
      expect(described_class.ledger(Samagotchi::Session.session_dir(parent.id, state_dir: state_dir)))
        .to eq([{ child_id: child.id, of: check_turn, author: "p:alex" }])
    end

    it "saves no mode for the owner's child (its turns stay the owner's)" do
      start(author: nil, mode: nil)
      expect(spawned.first[:verify_fresh].to_file).to eq("of" => check_turn,
                                                         "anchor" => { "turn_id" => source_turn, "quote" => anchor[:quote] })
    end

    it "refuses a verdict it doesn't have, one that isn't unclear, and a second check while one runs" do
      expect { start(of: "nope") }.to raise_error(described_class::Refused) { |e| expect([e.status, e.code]).to eq([404, "not_found"]) }

      parent.verdicts = [unclear.merge(verdict: "refuted")]
      parent.save(state_dir: state_dir)
      expect { start }.to raise_error(described_class::Refused) { |e| expect([e.status, e.code]).to eq([409, "not_unclear"]) }

      parent.verdicts = [unclear]
      parent.save(state_dir: state_dir)
      child = start
      expect(described_class.running(parent.id, state_dir: state_dir)).to eq([{ child_id: child.id, of: check_turn, author: "p:alex" }])
      expect { start }.to raise_error(described_class::Refused) { |e| expect([e.status, e.code]).to eq([409, "fresh_running"]) }

      Samagotchi::Session.load(child.id, state_dir: state_dir).tap { |s| s.status = Samagotchi::Session::STATUS_IDLE }
                         .save(state_dir: state_dir)
      expect(described_class.running(parent.id, state_dir: state_dir)).to eq([])
      expect { start }.not_to raise_error
      expect(spawned.size).to eq(2)
    end

    it "runs one fresh child per requester at a time, even when ten start at once" do
      ids = Array.new(10) { |i| format("33333333-3333-4444-5555-%012d", i) }
      parent.verdicts = ids.map { |id| unclear.merge(check_turn_id: id) }
      parent.save(state_dir: state_dir)

      results = ids.map { |id| Thread.new { start(of: id) rescue $! } }.map(&:value)
      refused = results.grep(described_class::Refused)
      expect(spawned.size).to eq(1)
      expect(refused.map(&:code).uniq).to eq(["fresh_busy"])
      expect(refused.size).to eq(9)

      # Another requester (the owner here) still gets one of their own.
      others = ids - [spawned.first[:verify_fresh].of]
      expect { start(of: others[0], author: nil, mode: nil) }.not_to raise_error
      expect { start(of: others[1], author: nil, mode: nil) }
        .to raise_error(described_class::Refused) { |e| expect(e.code).to eq("fresh_busy") }
    end

    it "refuses once the parent runs session.max_children children of any kind" do
      allow(Samagotchi::Tools::Delegate).to receive(:max_children).and_return(2)
      2.times do
        Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: folder, parent_id: parent.id,
                                        delegate: true).tap { |c| c.status = "running" }.save(state_dir: state_dir)
      end

      expect { start }.to raise_error(described_class::Refused) { |e| expect([e.status, e.code]).to eq([409, "children_full"]) }
      expect(spawned).to eq([])
    end

    it "starts a real child session outside git, saved with its field before its worker starts" do
      allow(Samagotchi::SessionManager).to receive(:spawn_worker_for_session)
      child = described_class.start(parent.id, of: check_turn, author: "p:alex", mode: :review, state_dir: state_dir)

      saved = Samagotchi::Session.load(child.id, state_dir: state_dir)
      expect([saved.working_directory, saved.parent_id, saved.delegate?]).to eq([folder, parent.id, true])
      expect(saved.messages).to eq([])
      expect(saved.verify_fresh.to_file).to include("author" => "p:alex", "mode" => "review", "of" => check_turn)
      expect(saved.participants_source_id).to eq(parent.id)
      expect(saved.last_prompt).to start_with("Claim:\n> the cache key")
    end
  end

  describe "the spend rollup" do
    def spend(session_id, author, cost)
      dir = Samagotchi::Session.session_dir(session_id, state_dir: state_dir)
      FileUtils.mkdir_p(dir)
      File.write(Samagotchi::AnalyticsFile.path(dir),
                 JSON.generate({ "turn_records" => [{ "id" => "t", "author" => author, "cost" => cost }] }))
    end

    it "counts a participant's fresh children for the parent, and the parent and the siblings for a child" do
      first = start
      Samagotchi::Session.load(first.id, state_dir: state_dir).tap { |s| s.status = "idle" }.save(state_dir: state_dir)
      parent.verdicts = [unclear, unclear.merge(check_turn_id: "33333333-3333-4444-5555-666666666666")]
      parent.save(state_dir: state_dir)
      second = start(of: "33333333-3333-4444-5555-666666666666")
      other = start(of: "33333333-3333-4444-5555-666666666666", author: "p:sam") rescue nil
      expect(other).to be_nil
      spend(parent.id, "p:alex", 0.5)
      spend(first.id, "p:alex", 0.25)
      spend(second.id, "p:alex", 1.0)

      expect(described_class.children_spend(parent.id, "p:alex", state_dir: state_dir)).to eq(1.25)
      expect(described_class.children_spend(parent.id, "p:sam", state_dir: state_dir)).to eq(0.0)
      expect(described_class.related_spend(parent, "p:alex", state_dir: state_dir)).to eq(1.25)
      child = Samagotchi::Session.load(second.id, state_dir: state_dir)
      expect(described_class.related_spend(child, "p:alex", state_dir: state_dir)).to eq(0.75)
      expect(described_class.related_spend(child, nil, state_dir: state_dir)).to eq(0.0)
    end
  end
end

RSpec.describe Samagotchi::VerifyFreshOrigin do
  let(:anchor) { { "turn_id" => "11111111-2222-3333-4444-555555555555", "quote" => "claim" } }

  it "reads a participant's field and runs their turns as theirs under the saved mode" do
    origin = described_class.of({ "author" => "p:alex", "mode" => "pair", "of" => "c1", "anchor" => anchor })
    expect(origin.turn_mode).to eq(:pair)
    turn = origin.origin_for(Samagotchi::TurnOrigin.new(client_id: "web:x"))
    expect([turn.author, turn.client_id]).to eq(["p:alex", "web:x"])
    expect(described_class.of(origin.to_file)).to eq(origin)
  end

  it "keeps the owner's child's turns the owner's" do
    origin = described_class.of({ "of" => "c1", "anchor" => anchor })
    expect(origin.participant?).to be(false)
    expect(origin.origin_for(Samagotchi::TurnOrigin::NONE).author).to be_nil
  end

  it "fails closed: a field that doesn't read is a participant nobody has, under review" do
    [{ "author" => "p:alex", "mode" => "admin", "of" => "c1", "anchor" => anchor },
     { "author" => "p:alex", "mode" => "pair", "of" => "c1" },
     { "author" => "owner", "mode" => "pair", "of" => "c1", "anchor" => anchor },
     "pair"].each do |value|
      origin = described_class.of(value)
      expect(origin).to eq(described_class::INVALID)
      expect(origin.turn_mode).to eq(:review)
      expect(origin.origin_for(Samagotchi::TurnOrigin::NONE).participant?).to be(true)
    end
    expect(described_class.of(nil)).to be_nil
  end
end
