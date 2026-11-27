# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_chain/successor"
require "samagotchi/session_continue"
require "samagotchi/session_access"
require "samagotchi/peer_say"
require "samagotchi/schedules"
require "samagotchi/session_manager"
require "samagotchi/session_transition"

# One message per condition (N2): a link continued, or being continued, is
# said in SessionChain::Continued's words at every site that refuses for it;
# each site adds only what to do next.
RSpec.describe Samagotchi::SessionChain::Continued do
  let(:old) { "4c1a2b3d-0000-4000-8000-000000000000" }
  let(:new) { "7b2d41aa-0000-4000-8000-000000000000" }

  def words(session_id = old, in_flight: false) = described_class.new(session_id, new, in_flight: in_flight).message

  it "owns the words: was continued, or is being continued, as the full successor id" do
    expect(words).to eq("session 4c1a2b3d was continued as #{new}")
    expect(words(in_flight: true)).to eq("session 4c1a2b3d is being continued as #{new}")
    expect(described_class.for(old, Samagotchi::SessionChain::Successor.new(id: new, via: :in_flight)).message)
      .to eq(words(in_flight: true))
  end

  it "names 'this session' without an id: the installed chi-peer skills look for those words" do
    expect(words(nil)).to eq("this session was continued as #{new}")
  end

  describe "every site that refuses for it" do
    it "SessionContinue::Refused :continued" do
      expect(Samagotchi::SessionContinue::Refused.new(old, :continued, ids: [new]).message)
        .to eq("#{words}; continue that one (or last:4c1a2b3d)")
    end

    it "a peer say and a peer pair" do
      expect(Samagotchi::PeerSay.new(status: :continued, next_id: new).line("claude")).to eq("#{words(nil)}: say it there")
      expect(Samagotchi::PeerPaired.new(status: :continued, next_id: new).refusal).to eq("#{words(nil)}: pair with it")
    end

    it "a context push" do
      expect(Samagotchi::SessionAccess::ContextPush.continued_message("notes", old, new))
        .to start_with("#{words}: notes stays with the session it was attached to")
    end

    it "a send whose link is still being continued (Head's :continuing)" do
      resolved = Samagotchi::SessionInbox::Resolved.new(id: new, asked: old, via: :continuing)
      expect(resolved.continuing_refusal).to eq("#{words(in_flight: true)}; send again in a moment")
    end

    context "with sessions on disk" do
      let(:root) { Dir.mktmpdir("continued-words") }
      let(:dir) { File.join(root, "sessions").tap { |d| FileUtils.mkdir_p(d) } }
      let(:old) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.tmpdir)
                           .tap { |s| s.save(state_dir: dir) }.id
      end

      after { FileUtils.rm_rf(root) }

      # A continue of old in flight: its intent, its lock held by another thread.
      def continuing
        folder = FileUtils.mkdir_p(Samagotchi::Session.session_dir(old, state_dir: dir)).first
        Samagotchi::ContinueIntent.write(File.join(folder, Samagotchi::ContinueIntent::FILE), successor_id: new,
                                                                                              previously_archived: [])
        taken = Queue.new
        release = Queue.new
        holder = Thread.new do
          Samagotchi::SessionTransition.exclusive(old, kind: :continue, state_dir: dir) do
            taken << true
            release.pop
          end
        end
        taken.pop
        yield
      ensure
        release << true
        holder&.join
      end

      it "a followed send (follow_guard)" do
        Samagotchi::ArchiveStore.archive(old, state_dir: dir)
        refused = continuing do
          Samagotchi::SessionManager.deliver_turn(old, prompt: "x", client_id: Samagotchi::ClientId::CLI_SEND,
                                                       follow: true, state_dir: dir)
        end
        expect(refused.ack["detail"]).to eq("#{words(in_flight: true)}; send again in a moment")
      end

      it "a schedule's firing at a link being continued" do
        reason = continuing { Samagotchi::Schedules.new(state_dir: dir).send(:continuing_reason, old) }
        expect(reason).to eq("#{words(in_flight: true)}; retry at the next tick")
      end
    end
  end
end
