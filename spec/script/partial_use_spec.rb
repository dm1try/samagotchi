# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../../script/partial_use/doors"
require_relative "../../script/partial_use/wide"

# script/partial-use: the two audit probes (a narrow door that drags a whole
# subtree, a wide class each client barely uses). Each fixture tree is a tiny
# lib/samagotchi written in a tmp dir; nothing is ever loaded.
RSpec.describe PartialUse do
  # The script's path, read through a method rather than a constant: a
  # top-level SCRIPT here would shadow another spec's.
  def tool
    File.expand_path("../../script/partial-use", __dir__)
  end

  def units(files)
    root = Dir.mktmpdir("partial-use-")
    files.each do |name, body|
      path = File.join(root, "lib/samagotchi", name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
    end
    PartialUse::Units.new(root: root)
  end

  def run(command, *flags)
    out, status = Open3.capture2(RbConfig.ruby, tool, command, *flags, stdin_data: "")
    [out, status.exitstatus]
  end

  describe PartialUse::Doors do
    # a.rb opens two doors: heavy.rb drags three more files and a.rb names one
    # of them; light.rb drags one and a.rb names none of it.
    DOORS = {
      "a.rb" => <<~RUBY,
        require_relative "heavy"
        require_relative "light"

        def run
          HeavyThing
        end
      RUBY
      "heavy.rb" => <<~RUBY,
        require_relative "part1"
        require_relative "part2"
        require_relative "part3"
      RUBY
      "part1.rb" => "class HeavyThing; end\n",
      "part2.rb" => "class Part2; end\n",
      "part3.rb" => "class Part3; end\n",
      "light.rb" => <<~RUBY,
        require_relative "small"
      RUBY
      "small.rb" => "class SmallThing; end\n"
    }

    def rows(files, **options)
      described_class.new(units(files), **options).report
    end

    it "ranks the door that drags the most files for the fewest names first" do
      rows = rows(DOORS)

      expect(rows.first).to have_attributes(from: "lib/samagotchi/a.rb", to: "lib/samagotchi/heavy.rb",
                                            added: 4, names: ["HeavyThing"])
      light = rows.find { _1.to == "lib/samagotchi/light.rb" }
      expect(light).to have_attributes(added: 2, names: [])
      expect(rows.map(&:added)).to eq(rows.map(&:added).sort.reverse)
    end

    it "drops the doors that add fewer than --min-files" do
      expect(rows(DOORS, min_files: 4).map(&:to)).to eq(["lib/samagotchi/heavy.rb"])
    end

    it "leaves the spec-helper doors out, and brings them back with --include-testing" do
      files = DOORS.merge({
        "testing/helper.rb" => <<~RUBY,
          require_relative "big"

          def run
            HelperThing
          end
        RUBY
        "testing/big.rb" => "class HelperThing; end\n"
      })

      helper = "lib/samagotchi/testing/helper.rb"
      expect(rows(files).map(&:from)).not_to include(helper)
      expect(rows(files, include_testing: true).map(&:from)).to include(helper)
    end

    it "counts a method called on a constant from the closure as a name" do
      rows = rows({
        "client.rb" => <<~RUBY,
          require_relative "door"

          def run
            DoorHelper.tick
          end
        RUBY
        "door.rb" => "require_relative \"inside\"\n",
        "inside.rb" => "class DoorHelper\n  def tick; end\nend\n"
      })

      expect(rows.first.to).to eq("lib/samagotchi/door.rb")
      expect(rows.first.added).to eq(2)
      expect(rows.first.names).to eq(["DoorHelper", "DoorHelper.tick"])
    end

    it "follows one client with --entry" do
      rows = rows(DOORS, entry: "lib/samagotchi/light.rb")

      expect(rows.map { _1.from }).to eq(["lib/samagotchi/light.rb"])
    end

    it "prints one line per door and the counts, and always exits 0" do
      out, status = run("doors")

      expect(status).to eq(0)
      expect(out).to match(/\Apartial-use doors: .+\n/)
      expect(out).to match(/^\s*\d+\s+\d+  \S+ -> \S+  \(names: .+\)\n/)
    end

    it "writes --json as one object per door" do
      out, status = run("doors", "--limit", "2", "--json")

      expect(status).to eq(0)
      rows = JSON.parse(out)
      expect(rows.size).to eq(2)
      expect(rows.first).to include("from", "to", "added", "names")
    end

    it "keeps lib/samagotchi/testing/ doors out of the report unless --include-testing" do
      without, = run("doors", "--limit", "50")
      with, = run("doors", "--limit", "50", "--include-testing")

      expect(without).not_to match(%r{lib/samagotchi/testing/.* -> })
      expect(with).to match(%r{lib/samagotchi/testing/.* -> })
    end
  end

  describe PartialUse::Wide do
    WIDE = {
      "widget.rb" => <<~RUBY,
        class Widget
          def one; end
          def two; end
          def three; end
          def four; end

          private

          def helper; end

          class Inner
            def deep; end
            private
            def secret; end
          end
        end
      RUBY
      "narrow.rb" => <<~RUBY,
        def run
          Widget.one
        end
      RUBY
      "elsewhere.rb" => <<~RUBY,
        def run
          Widget
          thing.two
        end
      RUBY
      "inner_user.rb" => <<~RUBY
        def run
          Widget::Inner.deep
        end
      RUBY
    }

    # Four namespaces, two clients each: Big and Tiny are named but never
    # called, Narrow is called once directly, Nest::Broad only through an
    # object; the root module is not a door anyone uses.
    RANK = {
      "big.rb" => <<~RUBY,
        class Big
          def b1; end
          def b2; end
          def b3; end
          def b4; end
          def b5; end
          def b6; end
        end
      RUBY
      "tiny.rb" => <<~RUBY,
        class Tiny
          def t1; end
          def t2; end
          def t3; end
          def t4; end
        end
      RUBY
      "narrow.rb" => <<~RUBY,
        class Narrow
          def n1; end
          def n2; end
          def n3; end
          def n4; end
        end
      RUBY
      "broad.rb" => <<~RUBY,
        module Nest
          class Broad
            def a1; end
            def a2; end
            def a3; end
            def a4; end
            def a5; end
            def a6; end
          end
        end
      RUBY
      "root.rb" => <<~RUBY,
        module Samagotchi
          def r1; end
          def r2; end
          def r3; end
          def r4; end
          def r5; end
          def r6; end
        end
      RUBY
      "user_big1.rb" => "def run\n  Big\nend\n",
      "user_big2.rb" => "def run\n  Big\nend\n",
      "user_tiny1.rb" => "def run\n  Tiny\nend\n",
      "user_tiny2.rb" => "def run\n  Tiny\nend\n",
      "user_narrow1.rb" => "def run\n  Narrow.n1\nend\n",
      "user_narrow2.rb" => "def run\n  Narrow\nend\n",
      "user_broad1.rb" => "def run\n  Nest::Broad\n  thing.a1\n  thing.a2\nend\n",
      "user_broad2.rb" => "def run\n  Nest::Broad\nend\n",
      "user_root1.rb" => "def run\n  Samagotchi\nend\n",
      "user_root2.rb" => "def run\n  Samagotchi\nend\n"
    }

    def rows(files, **options)
      described_class.new(units(files), **options).report
    end

    it "reports a client that calls one of four public methods as 25%" do
      row = rows(WIDE, min_public: 4).first

      expect(row).to have_attributes(name: "Widget", count: 4)
      expect(row.clients.map(&:to_h)).to eq([
        { path: "lib/samagotchi/narrow.rb", qualified: 1, any: 1, share: 0.25 },
        { path: "lib/samagotchi/elsewhere.rb", qualified: 0, any: 1, share: 0.0 }
      ])
      expect(row.max_share).to eq(0.25)
      expect(row.any_share).to eq(0.25)
    end

    it "keeps private methods out of the count and each namespace on its own" do
      wide = rows(WIDE, min_public: 1, min_clients: 1)
      widget = wide.find { _1.name == "Widget" }
      inner = wide.find { _1.name == "Widget::Inner" }

      expect(widget.count).to eq(4)
      expect(inner.count).to eq(1)
      expect(inner.clients.map(&:path)).to eq(["lib/samagotchi/inner_user.rb"])
    end

    it "lists a namespace only when at least --min-clients files name it" do
      expect(rows(WIDE, min_public: 1).map(&:name)).to eq(["Widget"])
      expect(rows(WIDE, min_public: 1, min_clients: 1).map(&:name)).to eq(["Widget", "Widget::Inner"])
    end

    it "ranks by the smallest any share, then by the widest class, and skips the root module" do
      rows = rows(RANK, min_public: 4)

      expect(rows.map(&:name)).to eq(["Big", "Tiny", "Narrow", "Nest::Broad"])
      expect(rows.map(&:any_share)).to eq([0.0, 0.0, 0.25, 1.0 / 3])
      expect(rows.map(&:max_share)).to eq([0.0, 0.0, 0.25, 0.0])
    end

    it "honours --min-public" do
      expect(rows(WIDE).map(&:name)).to be_empty
    end

    it "ranks by any share first and width second" do
      wide = rows(RANK, min_public: 1)
      keys = wide.map { [_1.any_share, -_1.count] }

      expect(keys).to eq(keys.sort)
    end

    it "prints one block per class and always exits 0" do
      out, status = run("wide", "--min-public", "40")

      expect(status).to eq(0)
      expect(out).to match(/\Apartial-use wide: .+\n/)
      expect(out).to match(/^\S+ +\d+ public .+\n/)
      expect(out).to match(%r{^  \S+ +\d+/\d+ \(\d+%\)  any \d+/\d+ \(\d+%\)\n})
    end

    it "writes --json as one object per class" do
      out, status = run("wide", "--min-public", "40", "--limit", "3", "--json")

      expect(status).to eq(0)
      rows = JSON.parse(out)
      expect(rows.size).to be_positive
      expect(rows.first).to include("name", "count", "max_share", "any_share", "clients")
    end

    it "lists no namespace with a single client unless --min-clients 1" do
      without, = run("wide", "--min-public", "40", "--limit", "50")
      with, = run("wide", "--min-public", "40", "--min-clients", "1", "--limit", "50")

      expect(without).not_to include(" 1 clients")
      expect(with).to include(" 1 clients")
    end
  end

  it "--help says what the two reports mean" do
    out, status = run("--help")

    expect(status).to eq(0)
    expect(out).to include("usage: script/partial-use doors")
    expect(out).to include("upper bound")
    expect(out).to include("--min-clients")
    expect(out).to include("--include-testing")
  end
end
