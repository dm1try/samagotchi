# frozen_string_literal: true

require "fileutils"
require "open3"
require "prism"
require "tmpdir"
require_relative "../../script/dead_code/scan"

# script/dead-code: the methods under lib/ that nothing names (advisory).
RSpec.describe DeadCode::Scan do
  let(:root) { Dir.mktmpdir("dead-code-") }

  after { FileUtils.rm_rf(root) }

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  before do
    write("lib/thing.rb", <<~RUBY)
      class Thing
        def ready? = true
        def has_options? = true
        def used = 1
        def orphan = 2
      end
    RUBY
    write("spec/thing_spec.rb", <<~RUBY)
      RSpec.describe Thing do
        it { expect(Thing.new).to be_ready }
        it { expect(Thing.new).to have_options }
        it { expect(Thing.new.used).to eq(1) }
      end
    RUBY
  end

  it "reports a method nothing names, not one a spec uses only as be_foo (foo?) or have_foo (has_foo?)" do
    rows = described_class.new(root: root).run.rows

    expect(rows.map(&:name)).to eq(["orphan"])
    expect(rows.first).to have_attributes(path: "lib/thing.rb", line: 5, notes: [])
  end

  it "notes a name built at run time from an interpolated prefix" do
    write("lib/events.rb", <<~'RUBY')
      class Events
        def emit(event) = public_send("on_#{event}")
        def on_tick = nil
      end
    RUBY

    row = described_class.new(root: root).run.rows.find { _1.name == "on_tick" }

    expect(row.notes).to eq(["dyn-prefix", "dispatched by name (on_<event>)"])
    expect(row).to be_explained
  end

  it "prints path:line name and a count, and exits 0 (advisory)" do
    script = File.expand_path("../../script/dead-code", __dir__)
    out, status = Open3.capture2(RbConfig.ruby, script, stdin_data: "")

    expect(status.exitstatus).to eq(0)
    expect(out).to match(/unreferenced def sites \(\d+ names\) of \d+ defs; \d+ with no explaining note\n\z/)
  end
end
