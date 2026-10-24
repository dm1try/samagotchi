# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "samagotchi/testing/rspec"

# The ruby plugin (lib/samagotchi/bundles/ruby): an `execute` that ran RSpec
# with no examples at all steers a hint into the turn. Its one hook, driven
# through the bundle test kit with execute results as Execute prints them
# (`stdout:` block, `exit: 0` last);
# spec/samagotchi/plugin/ruby_bundle_spec.rb installs the bundle and loads
# it in an Engine.
RSpec.describe "The ruby bundle", :bundle do
  let(:bundle) { shipped_bundle("ruby") }
  let(:hint) { "rspec ran 0 examples: check the path, the filter (-e/--tag) or the .rspec --pattern" }

  # An execute result as Execute makes it: the output as its own block, the
  # exit code last.
  def result(output, exit_code: 0) = "stdout:\n#{output}\nexit: #{exit_code}"

  def zero(lines = ["0 examples, 0 failures"]) = result(lines.join("\n\n"))

  def execute(command, output: zero, tool: "execute")
    bundle.fire(:after_tool_call, tool: tool, status: "ok", call: { name: tool, content: command }, result: output)
  end

  def steers = bundle.steers.map(&:text)

  describe "a command that ran rspec" do
    it "steers the hint for `bundle exec rspec` with no examples" do
      execute("bundle exec rspec")

      expect(steers).to eq([hint])
    end

    it "steers for a plain rspec, its arguments, bin/rspec and after `cd x &&`" do
      ["rspec", "rspec spec/a_spec.rb", "bin/rspec spec", "./bin/rspec", "cd pkg && bundle exec rspec",
       "cd pkg && rspec spec", "RAILS_ENV=test bundle exec rspec", "rspec 2>&1 | tail -5"].each do |command|
        execute(command)
      end

      expect(steers.size).to eq(8)
    end

    it "names the hint once per run, as the plugin's own steer" do
      execute("bundle exec rspec")
      execute("bundle exec rspec")

      expect(steers).to eq([hint, hint])
      expect(bundle.steers.map(&:hook).uniq).to eq(["plugin.rb (bundle ruby)"])
    end
  end

  describe "a command that didn't run rspec" do
    it "stays quiet, even with the same output" do
      ["bundle exec rails test", "npm test", "grep rspec README.md", "echo 'bundle exec rspec'",
       "bundle exec rubocop"].each do |command|
        execute(command)
      end

      expect(steers).to be_empty
    end

    it "stays quiet for another tool's output" do
      execute("bundle exec rspec", tool: "read")

      expect(steers).to be_empty
    end
  end

  describe "the summary line" do
    it "steers for `0 examples, 0 failures`, with pending examples or not" do
      execute("rspec", output: zero(["0 examples, 0 failures"]))
      execute("rspec", output: zero(["0 examples, 0 failures, 3 pending"]))
      execute("rspec", output: zero(["[stdout] 0 examples, 0 failures"]))
      execute("rspec", output: result("\nFinished in 0.001 seconds (files took 0.2 seconds to load)\n0 examples, 0 failures\n"))

      expect(steers.size).to eq(4)
    end

    it "stays quiet for one example or more" do
      ["1 example, 0 failures", "3 examples, 0 failures", "12 examples, 2 failures"].each do |summary|
        execute("rspec", output: zero([summary]))
      end

      expect(steers).to be_empty
    end

    it "stays quiet when the output has no summary line (it crashed)" do
      execute("rspec", output: result("An error occurred while loading ./spec/x_spec.rb.\nFailure/Error: require \"x\"",
                                      exit_code: 1))
      execute("rspec", output: result("", exit_code: 1))
      execute("rspec", output: "Error: command timed out after 120s\n(killed at the limit)")

      expect(steers).to be_empty
    end

    describe "parallel_rspec, one summary line per process" do
      it "steers when every process counted 0 examples" do
        execute("bundle exec parallel_rspec spec", output: zero(["0 examples, 0 failures", "0 examples, 0 failures"]))

        expect(steers).to eq([hint])
      end

      it "stays quiet when the total isn't 0" do
        execute("bundle exec parallel_rspec spec",
                output: zero(["5 examples, 0 failures", "0 examples, 0 failures"]))

        expect(steers).to be_empty
      end
    end
  end
end

# The ruby_symbol tool (RubySymbol in plugin.rb): a file's outline, a def or
# class by name with its source, the same across a directory's .rb files.
RSpec.describe "The ruby bundle's ruby_symbol tool", :bundle do
  let(:dir) { Dir.mktmpdir("ruby-symbol") }
  let(:bundle) { shipped_bundle("ruby", host: { cwd: dir }) }
  let(:source) do
    <<~RUBY
      module Shop
        class Cart < Base
          def initialize(items = [],
                         owner: nil)
            @items = items
          end

          def add(item) = @items << item

          def self.empty
            new
          end

          class << self
            def restore(data)
              new(data)
            end
          end
        end

        Point = Data.define(:x, :y) do
          def norm = Math.sqrt((x * x) + (y * y))
        end
      end

      def Shop.open?
        true
      end
    RUBY
  end

  after { FileUtils.rm_rf(dir) }

  def write(path, text)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
    full
  end

  def symbol(**args) = bundle.tool("ruby_symbol", args)

  # The lines start..finish of +path+ as the file has them.
  def lines(path, start, finish) = File.read(File.join(dir, path)).lines[(start - 1)...finish].join

  before { write("lib/shop.rb", source) }

  it "registers the tool" do
    expect(bundle.bundle_tools.map(&:name)).to eq(["ruby_symbol"])
  end

  it "targets its path for the path rules, the session's cwd with no path" do
    paths = lambda do |args|
      bundle.before_tool_call_event({ name: "ruby_symbol", args: args }, params: "ruby_symbol")[:targets][:paths]
    end

    expect(paths.call({ "path" => "lib/shop.rb" })).to eq([File.join(dir, "lib/shop.rb")])
    expect(paths.call({ "name" => "Cart" })).to eq([dir])
  end

  it "outlines a file: one line per class, module and def, nested, with their ranges and params" do
    expect(symbol(path: "lib/shop.rb")).to eq(<<~OUT.chomp)
      1-24   module Shop
      2-19     class Cart < Base
      3-6        def initialize(items = [], owner: nil)
      8-8        def add(item)
      10-12      def self.empty
      14-18      class << self
      15-17        def restore(data)
      21-23    Point = Data.define(:x, :y)
      22-22      def norm
      26-28  def Shop.open?
    OUT
  end

  it "says a file with nothing to outline has none" do
    write("empty.rb", "puts 1\n")

    expect(symbol(path: "empty.rb")).to eq("empty.rb: no class, module or def")
  end

  describe "a name in a file" do
    it "returns the def's raw lines, byte for byte, after a path:start-end header" do
      expect(symbol(path: "lib/shop.rb", name: "initialize")).to eq("lib/shop.rb:3-6\n#{lines("lib/shop.rb", 3, 6)}")
    end

    it "finds each name form" do
      {
        "add" => "8-8", "Cart#add" => "8-8", "Shop::Cart#add" => "8-8", "Cart.empty" => "10-12",
        "Cart.restore" => "15-17", "Shop.open?" => "26-28", "Cart" => "2-19", "Shop::Cart" => "2-19",
        "Shop" => "1-24", "Point" => "21-23", "Point#norm" => "22-22", "::Shop::Point" => "21-23"
      }.each do |name, range|
        expect(symbol(path: "lib/shop.rb", name: name).lines.first.chomp).to eq("lib/shop.rb:#{range}"), name
      end
    end

    it "keeps instance and class methods apart" do
      expect(symbol(path: "lib/shop.rb", name: "Cart#empty")).to start_with("Error: no def or class named Cart#empty")
      expect(symbol(path: "lib/shop.rb", name: "Cart.add")).to start_with("Error: no def or class named Cart.add")
    end

    it "says no match, with the near names: the same name in another namespace" do
      expect(symbol(path: "lib/shop.rb", name: "Basket#add")).to eq(<<~OUT.chomp)
        Error: no def or class named Basket#add in lib/shop.rb. Near names:
        lib/shop.rb:8-8  Shop::Cart#add
      OUT
      expect(symbol(path: "lib/shop.rb", name: "nothing")).to eq("Error: no def or class named nothing in lib/shop.rb")
    end

    it "doesn't raise on a class with a dynamic namespace" do
      write("dynamic.rb", "class Class.new(Foo::Bar)::Baz\n  def run; end\nend\nX = Class.new(Foo::Bar) { def go; end }\n")

      expect(symbol(path: "dynamic.rb", name: "Baz#run")).to eq("dynamic.rb:2-2\n  def run; end\n")
      expect(symbol(path: "dynamic.rb", name: "X#go").lines.first).to eq("dynamic.rb:4-4\n")
    end
  end

  describe "a name in a directory" do
    it "searches the working directory by default, with each match's source when there are few" do
      expect(symbol(name: "Cart#add")).to eq("lib/shop.rb:8-8\n    def add(item) = @items << item\n")
    end

    it "lists the locations when there are more than 3, skipping vendor/" do
      5.times { |i| write("lib/m#{i}.rb", "class M#{i}\n  def call\n  end\nend\n") }
      write("vendor/gem/x.rb", "class V\n  def call; end\nend\n")

      expect(symbol(path: "lib", name: "call")).to eq(<<~OUT.chomp)
        5 matches: give a fuller name (Foo#bar, Foo::Bar) or a file as path, or read one's path:start-end
        lib/m0.rb:2-3  M0#call
        lib/m1.rb:2-3  M1#call
        lib/m2.rb:2-3  M2#call
        lib/m3.rb:2-3  M3#call
        lib/m4.rb:2-3  M4#call
      OUT
    end

    it "lists git's files in a work tree, leaving out what .gitignore ignores" do
      system("git", "-C", dir, "init", "-q", exception: true)
      write(".gitignore", "build/\n")
      write("build/cart.rb", "class Cart\n  def add; end\nend\n")

      expect(symbol(name: "Cart#add")).to start_with("lib/shop.rb:8-8\n")
    end

    it "asks for a name" do
      expect(symbol(path: "lib")).to eq("Error: give a name to search lib (or a .rb file as path for its outline)")
    end
  end

  it "says a path that doesn't exist" do
    expect(symbol(path: "nope.rb")).to eq("Error: no such file or directory: nope.rb")
  end

  it "cuts a long result at a line boundary under 8000 characters, with its own note" do
    body = (1..400).map { |i| "    x#{i} = #{i} # a line long enough to add up\n" }.join
    write("big.rb", "class Big\n  def huge\n#{body}  end\nend\n")

    result = symbol(path: "big.rb", name: "huge")
    kept, note = result.rpartition("\n").values_at(0, 2)

    expect(result.length).to be < 8200
    expect(kept).to end_with("# a line long enough to add up")
    expect(note).to match(/\A\[ruby_symbol: cut at \d+ of \d+ chars: narrow the name, or read a path:start-end above\]\z/)
  end

  it "registers no tool on a Prism below 1.0, the hook still there" do
    stub_const("Prism::VERSION", "0.19.0")

    expect(bundle.bundle_tools).to be_empty
    expect(bundle.hook_names(:after_tool_call)).not_to be_empty
  end
end
