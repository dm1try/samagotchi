# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "samagotchi/bundle_command"
require "samagotchi/bundle_command/scaffold"

# `chi bundle test`: a bundle's tests on chi's Ruby and lib, the runner's
# exit status passed through.
RSpec.describe "chi bundle test" do
  let(:tmp) { File.realpath(Dir.mktmpdir("bundle-test-")) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:bundle) { Samagotchi::BundleCommand::Scaffold.new("greet", parent: tmp).tap(&:write).dir }

  after { FileUtils.rm_rf(tmp) }

  def chi_test(*args) = Samagotchi::BundleCommand.new(["test", *args], stdout: out, stderr: err).run

  # The child writes to the real stdout: capture it there.
  def run_quietly(*args)
    status = nil
    output = capture_fd_output { status = chi_test(*args) }
    [status, output]
  end

  def capture_fd_output
    reader, writer = IO.pipe
    saved = $stdout.dup
    $stdout.reopen(writer)
    yield
    $stdout.flush
    $stdout.reopen(saved)
    writer.close
    reader.read
  ensure
    saved&.close
  end

  it "runs test/*_test.rb on Minitest: green exits 0, red exits 1, and ARGS go to the runner" do
    status, output = run_quietly(bundle)
    expect([status, output]).to match([0, a_string_including("2 runs, 3 assertions, 0 failures, 0 errors")])
    expect(out.string).to start_with("chi bundle test: 1 test file on #{RbConfig.ruby}")

    status, output = run_quietly(bundle, "--", "-n", "/greets/")
    expect([status, output]).to match([0, a_string_including("1 runs, 2 assertions, 0 failures")])

    test = File.join(bundle, "test", "greet_test.rb")
    File.write(test, File.read(test).sub('"hello, chi"', '"bye, chi"'))
    status, output = run_quietly(bundle)
    expect([status, output]).to match([1, a_string_including("1 failures")])
  end

  it "runs a spec/ (no test/) on RSpec with the kit (a group outside bundles/NAME/spec/ is tagged :bundle)" do
    FileUtils.mkdir_p(File.join(tmp, "b", "spec"))
    File.write(File.join(tmp, "b", "spec", "b_spec.rb"), <<~RUBY)
      RSpec.describe "b", :bundle do
        it("has the kit") { expect(sandbox.root).to include("chi-bundle-test-") }
      end
    RUBY

    status, output = run_quietly(File.join(tmp, "b"))
    expect([status, output]).to match([0, a_string_including("1 example, 0 failures")])
  end

  it "exits 1 with a hint when there are no tests, 2 for a PATH that isn't a folder" do
    FileUtils.mkdir_p(File.join(tmp, "empty"))
    expect(chi_test(File.join(tmp, "empty"))).to eq(1)
    expect(err.string).to include("no test/*_test.rb or spec/ in #{tmp}/empty (chi bundle new NAME writes a test to copy)")
    expect(chi_test(File.join(tmp, "nope"))).to eq(2)
    expect(chi_test("a", "b")).to eq(2)
  end
end
