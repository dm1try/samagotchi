# frozen_string_literal: true

require_relative "../../script/affected_specs/timing_hints"

# script/affected-specs' timing hints, from a changed spec's added lines.
RSpec.describe AffectedSpecs::TimingHints do
  # Answers added_lines(path) from a { path => [added line, …] } hash,
  # numbered from 1, and read(path) from { path => the whole file }.
  AddedTree = Struct.new(:added, :files) do
    def added_lines(path) = Array(added[path]).each_with_index.map { |text, index| [index + 1, text] }
    def read(path) = files[path]
  end

  def hints(added, files = {}) = described_class.new(changed: added.keys, tree: AddedTree.new(added, files)).hints

  it "hints at an added Thread.new with nothing added that waits for it" do
    expect(hints("spec/a_spec.rb" => ["it 'x' do", "  t = Thread.new { work }"]))
      .to eq(["timing: spec/a_spec.rb:2 starts a thread (Thread.new) #{described_class::STARTED}"])
  end

  it "hints at an added .start" do
    expect(hints("spec/a_spec.rb" => ["scheduler.start", "expect(x.name.start_with?(\"a\")).to be(true)"]))
      .to eq(["timing: spec/a_spec.rb:1 calls .start #{described_class::STARTED}"])
  end

  it "hints at an added spawn, but not at a spawn: keyword" do
    expect(hints("spec/a_spec.rb" => ["run_chi(spawn: true)", "pid = Process.spawn(\"ruby\")", "spawn(\"x\")"]))
      .to eq(["timing: spec/a_spec.rb:2,3 spawns a process #{described_class::STARTED}"])
  end

  it "does not hint at a bare spawn( in a file that defines its own spawn helper (its Process.spawn is stubbed)" do
    helper = <<~RB
      def spawn(toolkit = nil)
        described_class.spawn_session(toolkit: toolkit)
      end
    RB
    added = { "spec/session_manager_spec.rb" => ["    spawn(\"typo\")", "    spawn(\"web\")"] }

    expect(hints(added, { "spec/session_manager_spec.rb" => helper })).to eq([])
  end

  it "still hints at Process.spawn in a file with its own spawn helper" do
    expect(hints({ "spec/a_spec.rb" => ["pid = Process.spawn(\"ruby\", \"-e\", \"sleep 1\")", "spawn(\"x\")"] },
                 { "spec/a_spec.rb" => "def spawn(*args) = stubbed(*args)\n" }))
      .to eq(["timing: spec/a_spec.rb:1 spawns a process #{described_class::STARTED}"])
  end

  it "hints at a bare spawn( when the file defines no spawn helper: Kernel#spawn starts a process" do
    expect(hints("spec/rubocop/spec_sleep_spec.rb" => ["spawn(\"sh\", \"-c\", \"sleep 5; echo done\")"]))
      .to eq(["timing: spec/rubocop/spec_sleep_spec.rb:1 spawns a process #{described_class::STARTED}"])
  end

  it "hints at an added fork block, but not at a session's fork" do
    expect(hints("spec/a_spec.rb" => ["child = session.fork(id)", "pid = fork do", "Process.fork { exit! }"]))
      .to eq(["timing: spec/a_spec.rb:2,3 forks #{described_class::STARTED}"])
  end

  it "hints at an added sub-second be < bound" do
    expect(hints("spec/a_spec.rb" => ["expect(took).to be < 0.5", "expect(took).to be <= 2", "expect(count).to be < 10"]))
      .to eq(["timing: spec/a_spec.rb:1 #{described_class::BOUNDED}"])
  end

  it "gives no start hint when a join!, wait_for, with_task_dir or Process.wait is added with it" do
    ["join!(t, \"the worker\")", "wait_for(\"ready\") { up? }", "with_task_dir { example.run }", "Process.wait2(pid)"].each do |wait|
      expect(hints("spec/a_spec.rb" => ["t = Thread.new { work }", wait])).to eq([])
    end
  end

  it "reads only spec files and spec support, not comments, lib or fixtures" do
    added = { "lib/samagotchi/worker.rb" => ["Thread.new { run }"], "spec/fixtures/x/y.rb" => ["Thread.new {}"],
              "spec/support/web.rb" => ["# Thread.new runs it", "thread = Thread.new { run }"],
              "lib/samagotchi/bundles/b/spec/b_spec.rb" => ["fork { exit! }"] }
    expect(hints(added)).to eq([
      "timing: spec/support/web.rb:2 starts a thread (Thread.new) #{described_class::STARTED}",
      "timing: lib/samagotchi/bundles/b/spec/b_spec.rb:1 forks #{described_class::STARTED}"
    ])
  end
end
