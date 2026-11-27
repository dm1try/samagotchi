# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_transition"
require "samagotchi/continue_intent"

# SessionTransition: a session's transition lock (continue.lock), the token
# a holding thread passes through, and the kernel probe.
RSpec.describe Samagotchi::SessionTransition do
  let(:state_dir) { Dir.mktmpdir("session-transition") }
  let(:low) { "aaaaaaaa-0000-4000-8000-000000000001" }
  let(:high) { "ffffffff-0000-4000-8000-000000000002" }
  let(:holders) { [] }

  after do
    holders.each do |pid|
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    ensure
      Process.wait(pid) rescue nil
    end
    FileUtils.rm_rf(state_dir)
  end

  def dir_of(id) = Samagotchi::Session.session_dir(id, state_dir: state_dir)
  def lock_file(id) = File.join(dir_of(id), described_class::LOCK)
  def held?(id) = described_class.held?(id, state_dir: state_dir)
  def shared(id, &) = described_class.shared(id, state_dir: state_dir, &)
  def exclusive(ids, **, &) = described_class.exclusive(ids, kind: :continue, state_dir: state_dir, **, &)

  # Another process holding +id+'s lock on its own descriptor (+mode+ a
  # flock mode), until the spec kills it.
  def hold_elsewhere(id, mode: "LOCK_EX")
    FileUtils.mkdir_p(dir_of(id))
    holders << spawn_lock_holder(dir_of(id), holding: <<~RUBY)
      $held = File.open(File.join(ARGV[0], #{described_class::LOCK.inspect}), File::RDWR | File::CREAT, 0o600)
      $held.flock(File::#{mode})
    RUBY
  end

  # +id+'s lock held exclusively on a descriptor of this process; the
  # example closes it.
  def raw_lock(id)
    FileUtils.mkdir_p(dir_of(id))
    File.open(lock_file(id), File::RDWR | File::CREAT, 0o600).tap { |file| file.flock(File::LOCK_EX) } # rubocop:disable Style/FileOpen -- held open on purpose, closed by the example
  end

  # The value of +block+ run on another thread.
  def on_other_thread(&)
    thread = Thread.new(&)
    thread.report_on_exception = false
    thread.value
  end

  it "keeps the lock file's name: an older chi's continue and delete honour continue.lock" do
    expect(described_class::LOCK).to eq("continue.lock")
    expect(Samagotchi::ContinueIntent::LOCK).to eq(described_class::LOCK)
  end

  describe ".exclusive" do
    it "holds the lock for the block, creating the folder, returns the block's value and lets go after" do
      result = exclusive([low]) do |token|
        expect(token).to eq(described_class::Token.new(ids: [low], kind: :continue))
        expect(held?(low)).to be(true)
        :done
      end

      expect(result).to eq(:done)
      expect(File.file?(lock_file(low))).to be(true)
      expect(held?(low)).to be(false)
      expect(described_class.holding?(low, state_dir: state_dir)).to be(false)
    end

    it "lets go when the block raises or returns early" do
      expect { exclusive([low]) { raise "boom" } }.to raise_error("boom")
      expect(held?(low)).to be(false)

      early = -> { exclusive([low]) { return :early } }
      expect(early.call).to eq(:early)
      expect(held?(low)).to be(false)
    end

    it "passes a thread's own hold through: a nested exclusive and a shared one don't touch the file" do
      exclusive([low]) do
        expect(described_class.holding?(low, state_dir: state_dir)).to be(true)
        expect(exclusive([low], deadline: 0) { :nested }).to eq(:nested)
        expect(shared(low) { |held| held }).to be(true)
        # Still held after the nested block: it took and let go nothing.
        expect(described_class.holding?(low, state_dir: state_dir)).to be(true)
        expect(held?(low)).to be(true)
      end
      expect(held?(low)).to be(false)
    end

    it "takes only the ids not held yet inside a hold, and lets go only those" do
      exclusive([low]) do
        exclusive([high, low]) do |token|
          expect(token.ids).to eq([low, high])
          expect(held?(high)).to be(true)
        end
        expect(held?(high)).to be(false)
        expect(described_class.holding?(low, state_dir: state_dir)).to be(true)
      end
    end

    it "is per thread: another thread is refused while one holds it" do
      exclusive([low]) do
        expect(on_other_thread { described_class.holding?(low, state_dir: state_dir) }).to be(false)
        expect(on_other_thread { shared(low) { |held| held } }).to be(false)
        expect { on_other_thread { exclusive([low], deadline: 0.05) { :never } } }
          .to raise_error(described_class::Busy) { |busy| expect(busy.session_id).to eq(low) }
      end
    end

    it "takes several ids in sorted order: the lowest first, the rest untouched when it is busy" do
      hold_elsewhere(low)

      expect { exclusive([high, low], deadline: 0) { :never } }
        .to raise_error(described_class::Busy) { |busy| expect(busy.session_id).to eq(low) }
      expect(File.exist?(lock_file(high))).to be(false)
    end

    it "lets go of the ids it took when a later one is busy" do
      hold_elsewhere(high)

      expect { exclusive([high, low], deadline: 0) { :never } }
        .to raise_error(described_class::Busy) { |busy| expect(busy.session_id).to eq(high) }
      expect(held?(low)).to be(false)
      expect(described_class.holding?(low, state_dir: state_dir)).to be(false)
    end

    it "raises Busy after its deadline while another process holds it, shared too, the text its own" do
      hold_elsewhere(low, mode: "LOCK_SH")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { exclusive([low], deadline: 0.2) { :never } }.to raise_error(described_class::Busy) { |busy|
        expect(busy.kind).to eq(:continue)
        expect(busy.message).to eq("session #{low[0, 8]} is being continued; try again in a moment")
      }
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.2
    end

    it "names the kind's words, a plain busy for any other" do
      expect(described_class::Busy.new(low, kind: :delete).message).to eq("session #{low[0, 8]} is being deleted; try again in a moment")
      expect(described_class::Busy.new(low).message)
        .to eq("session #{low[0, 8]} is busy with another change; try again in a moment")
    end

    it "takes the lock once the other holder lets go within the deadline" do
      other = raw_lock(low)
      waiter = Thread.new { exclusive([low], deadline: 5) { :taken } }

      expect(waiter.join(0.2)).to be_nil
      other.close
      expect(waiter.value).to eq(:taken)
    ensure
      other&.close unless other&.closed?
    end

    it "blocks with no deadline until the lock is free" do
      other = raw_lock(low)
      waiter = Thread.new { exclusive([low]) { :taken } }

      expect(waiter.join(0.2)).to be_nil
      other.close
      expect(waiter.value).to eq(:taken)
    ensure
      other&.close unless other&.closed?
    end

    it "refuses an id that isn't a session id" do
      expect { exclusive(["../x"]) { :never } }.to raise_error(ArgumentError, /not a session id/)
    end
  end

  describe ".try_exclusive" do
    def try(id) = described_class.try_exclusive(id, kind: :repair, state_dir: state_dir) { |token| token }

    it "holds it once, and yields nil when anyone holds it: this thread too, another process" do
      FileUtils.mkdir_p(dir_of(low))
      expect(try(low)).to eq(described_class::Token.new(ids: [low], kind: :repair))
      expect(exclusive([low]) { try(low) }).to be_nil

      hold_elsewhere(high)
      expect(try(high)).to be_nil
    end

    it "creates no folder: a gone one raises ENOENT" do
      expect { try(low) }.to raise_error(Errno::ENOENT)
      expect(Dir.exist?(dir_of(low))).to be(false)
    end
  end

  describe ".shared" do
    it "is ContinueIntent.hold's: true and created when free, false for an id that isn't one" do
      expect(shared(low) { |held| [held, held?(low)] }).to eq([true, false])
      expect(File.file?(lock_file(low))).to be(true)
      expect(shared("../x") { |held| held }).to be(false)
    end

    it "is false while another process holds it exclusively, true beside another shared hold" do
      hold_elsewhere(low)
      hold_elsewhere(high, mode: "LOCK_SH")

      expect(shared(low) { |held| held }).to be(false)
      expect(shared(high) { |held| held }).to be(true)
    end
  end

  describe ".held?" do
    it "is a kernel probe: true inside this thread's own hold (the registry is not read)" do
      exclusive([low]) { expect(held?(low)).to be(true) }
    end

    it "is true for another process's hold, false for a shared one or none" do
      hold_elsewhere(low)
      hold_elsewhere(high, mode: "LOCK_SH")

      expect(held?(low)).to be(true)
      expect(held?(high)).to be(false)
    end

    it "creates nothing for a session with no folder or lock file" do
      expect(held?(low)).to be(false)
      expect(held?("../x")).to be(false)
      expect(Dir.exist?(dir_of(low))).to be(false)
    end
  end
end
