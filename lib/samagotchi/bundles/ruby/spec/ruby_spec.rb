# frozen_string_literal: true

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
