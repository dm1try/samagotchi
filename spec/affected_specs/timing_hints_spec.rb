# frozen_string_literal: true

require_relative "../../script/affected_specs/timing_hints"

# script/affected-specs' timing hints, from a changed spec's added lines.
RSpec.describe AffectedSpecs::TimingHints do
  # Answers added_lines(path) from a { path => [added line, …] } hash,
  # numbered from 1.
  AddedTree = Struct.new(:added) do
    def added_lines(path) = Array(added[path]).each_with_index.map { |text, index| [index + 1, text] }
  end

  def hints(added) = described_class.new(changed: added.keys, tree: AddedTree.new(added)).hints

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
