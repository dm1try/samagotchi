# frozen_string_literal: true

require "spec_helper"
require "samagotchi/session_access"
require "samagotchi/session_access/exchange"
require "samagotchi/session_manager"

RSpec.describe Samagotchi::SessionAccess::Exchange do
  let(:old_id) { "11111111-0000-4000-8000-000000000000" }
  let(:new_id) { "22222222-0000-4000-8000-000000000000" }
  # A backend that answers from scripted heads and records each call.
  let(:access) do
    Class.new do
      attr_accessor :heads, :session, :owner_value, :result, :reply
      attr_reader :calls

      def initialize = @calls = []

      def resolve(given)
        @calls << [:resolve, given]
        raise Samagotchi::Session::AmbiguousId.new("ambiguous #{given}", ids: %w[a b]) if given == "amb"
        raise Samagotchi::Session::NotFound, given if given == "none"

        given
      end

      def head(id)
        @calls << [:head, id]
        heads.size > 1 ? heads.shift : heads.first
      end

      def show(id) = (@calls << [:show, id]) && session
      def owner(id) = (@calls << [:owner, id]) && owner_value

      def deliver_turn(id, **options)
        @calls << [:deliver_turn, id, options]
        result
      end

      def wait_reply(id, **options)
        @calls << [:wait_reply, id, options]
        reply
      end
    end.new
  end
  let(:clock) { [0.0] }
  let(:pauses) { [] }
  let(:exchange) do
    described_class.new(access, pause: ->(s) { (pauses << s) && (clock[0] += s) }, continuing_wait: 1.0,
                                continuing_poll: 0.25, clock: -> { clock[0] })
  end

  def resolved(id, via: :same, asked: old_id) = Samagotchi::SessionInbox::Resolved.new(id: id, asked: asked, via: via)

  def session(status: Samagotchi::Session::STATUS_IDLE, model: "gemma4")
    Struct.new(:status, :model_name, :model_typed).new(status, model, nil)
  end

  def accepted(ack = { "enqueued_id" => "t1" })
    Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge, ack: ack)
  end

  describe "#locate" do
    it "names the head, not waited" do
      access.heads = [resolved(new_id, via: :head)]
      found = exchange.locate(old_id)
      expect(found).to eq(described_class::Located.new(target: resolved(new_id, via: :head), waited: false))
      expect(pauses).to be_empty
    end

    it "waits for a continue in flight, then names the new link (waited)" do
      access.heads = [resolved(new_id, via: :continuing), resolved(new_id, via: :head)]
      found = exchange.locate(old_id)
      expect(found.target.via).to eq(:head)
      expect(found.waited).to be(true)
      expect(pauses).to eq([0.25])
    end

    it "refuses a continue still in flight past the wait, naming the id asked" do
      access.heads = [resolved(new_id, via: :continuing)]
      found = exchange.locate(old_id)
      expect(found).to have_attributes(reason: :continuing, asked: old_id,
                                       message: "being continued as #{new_id[0, 8]}; send again in a moment")
      expect(pauses.sum).to be >= 1.0
    end

    it "ends the wait for a continue by deadline: when it comes before continuing_wait, its last pause cut to it" do
      access.heads = [resolved(new_id, via: :continuing)]
      expect(exchange.locate(old_id, deadline: 0.6)).to have_attributes(reason: :continuing)
      expect(pauses).to match([0.25, 0.25, 0.1].map { |s| be_within(1e-9).of(s) })
      expect(clock[0]).to be_within(1e-9).of(0.6)
    end

    it "is unknown for no such session, the error kept" do
      found = exchange.locate("none")
      expect(found).to have_attributes(reason: :unknown, message: "no session none")
      expect(found.error).to be_a(Samagotchi::Session::NotFound)
    end

    it "is unknown for an ambiguous prefix, the AmbiguousId kept" do
      found = exchange.locate("amb")
      expect(found.reason).to eq(:unknown)
      expect(found.error).to be_a(Samagotchi::Session::AmbiguousId).and(have_attributes(ids: %w[a b]))
    end
  end

  describe "#relocate" do
    let(:refused) { resolved(old_id) }

    it "answers another link once the head moved on" do
      access.heads = [resolved(old_id), resolved(new_id, via: :head)]
      again = exchange.relocate(refused, 5.0)
      expect(again.target.id).to eq(new_id)
      expect(pauses).to eq([0.25, 0.25])
    end

    it "answers an Unsent when the id no longer resolves" do
      refused = resolved("none", asked: "none")
      expect(exchange.relocate(refused, 5.0)).to have_attributes(reason: :unknown)
    end

    it "answers nil once out of time" do
      access.heads = [resolved(old_id)]
      expect(exchange.relocate(refused, 1.0)).to be_nil
    end

    it "bounds each look's own continue wait by the deadline when bounded (an ask's), not otherwise (chi send's)" do
      access.heads = [resolved(old_id, via: :continuing)]
      expect(exchange.relocate(refused, 0.5, bounded: true)).to have_attributes(reason: :continuing)
      expect(clock[0]).to be_within(1e-9).of(0.5)

      clock[0] = 0.0
      expect(exchange.relocate(refused, 0.5)).to have_attributes(reason: :continuing)
      expect(clock[0]).to be > 1.0
    end

    it "yields each look that waited on a continue" do
      access.heads = [resolved(new_id, via: :continuing), resolved(new_id, via: :head)]
      seen = []
      exchange.relocate(refused, 5.0) { |look| seen << look.target.id }
      expect(seen).to eq([new_id])
    end
  end

  describe "#attempt" do
    before do
      access.session = session
      access.result = accepted
    end

    it "sends to an idle session as a plain message, following a head" do
      pass = exchange.attempt(resolved(new_id, via: :head), "hi", client_id: "cli:send")
      expect(pass).to have_attributes(running: nil, delivery: nil, refs: [], result: accepted)
      expect(access.calls.map(&:first)).to eq(%i[show owner deliver_turn])
      expect(access.calls.last).to eq([:deliver_turn, new_id, { prompt: "hi", client_id: "cli:send", images: [],
                                                                delivery: nil, follow: true }])
    end

    it "queues to a running session with queue:" do
      access.session = session(status: Samagotchi::Session::STATUS_RUNNING)
      access.owner_value = :worker
      pass = exchange.attempt(resolved(old_id, via: :pinned), "next", client_id: "web:unnamed", queue: true)
      expect(pass).to have_attributes(running: true, delivery: Samagotchi::Delivery::QUEUE)
      expect(access.calls.last[2]).to include(delivery: Samagotchi::Delivery::QUEUE, follow: false)
    end

    it "asks a running turn for a cut with cut:, not an idle one" do
      access.session = session(status: Samagotchi::Session::STATUS_RUNNING)
      access.owner_value = :worker
      expect(exchange.attempt(resolved(old_id), "now", client_id: "cli:send", cut: true).delivery)
        .to eq(Samagotchi::Delivery::CUT)
      access.session = session
      expect(exchange.attempt(resolved(old_id), "now", client_id: "cli:send", cut: true).delivery).to be_nil
    end

    it "uploads the images to the target and sends their refs" do
      images = Struct.new(:ids) { def upload(id) = (ids << id) && [{ file: "a.png", name: "a" }] }.new([])
      pass = exchange.attempt(resolved(old_id), "see", client_id: "cli:send", images: images)
      expect(images.ids).to eq([old_id])
      expect(pass.refs).to eq([{ file: "a.png", name: "a" }])
    end

    it "stops on the check's refusal before the owner is read or anything sent" do
      pass = exchange.attempt(resolved(old_id), "see", client_id: "cli:send", check: ->(_s) { "no images here" })
      expect(pass).to eq(described_class::Stopped.new(target: resolved(old_id), refusal: "no images here"))
      expect(access.calls.map(&:first)).to eq(%i[show])
    end

    it "returns a continued result as is" do
      continued = Samagotchi::SessionManager::DeliverResult.new(
        status: :refused, code: 409, ack: { "error" => Samagotchi::SessionManager::DeliverResult::CONTINUED }
      )
      access.result = continued
      pass = exchange.attempt(resolved(old_id, via: :head), "hi", client_id: "cli:send")
      expect(pass.result).to be(continued)
      expect(access.calls.count { |c| c.first == :deliver_turn }).to eq(1)
    end
  end

  describe "#wait" do
    let(:target) { Samagotchi::ReplyWait::Target.new(turn: "t1", report_turn_id: "t1", cursor: "c", owner_grace: 5) }

    it "names the target's turn and scrubs the text to UTF-8" do
      access.reply = Samagotchi::ReplyWait::Result.new(status: :done, text: "ok \xFF".b, turn_id: nil)
      result = exchange.wait("id", target, timeout: 3, cancelled: -> { false })
      expect(result.turn_id).to eq("t1")
      expect(result.text).to eq("ok �")
      expect(result.text.encoding).to eq(Encoding::UTF_8)
      _, _, options = access.calls.last
      expect(options).to include(turn: "t1", cursor: "c", owner_grace: 5, timeout: 3)
      expect(options).not_to include(:poll_interval)
    end

    it "keeps the result's turn id when the target knows none, and passes a poll interval" do
      access.reply = Samagotchi::ReplyWait::Result.new(status: :done, text: nil, turn_id: "t9")
      result = exchange.wait("id", Samagotchi::ReplyWait::Target.new, timeout: 3, poll_interval: 0.1)
      expect(result.turn_id).to eq("t9")
      expect(access.calls.last[2]).to include(poll_interval: 0.1)
    end
  end

  it "binds an accepted message as ReplyWait::Target.message does" do
    start = Samagotchi::SessionAccess::WaitStart.new(cursor: "c", baseline: nil, own_turn: nil, known_turn: nil,
                                                     running: false, live: true, settled: false, last_turn_id: nil)
    expect(exchange.bind(start, accepted, queue: true))
      .to eq(Samagotchi::ReplyWait::Target.message(start, accepted, queue: true))
  end
end
