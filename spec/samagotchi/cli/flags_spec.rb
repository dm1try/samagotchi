# frozen_string_literal: true

require "spec_helper"
require "samagotchi/cli/flags"

RSpec.describe Samagotchi::CLI::Flags do
  let(:flags) do
    described_class.new(help: %w[-h --help]) do |f|
      f.value "-m", "--message"
      f.value "--image", key: :images, repeat: true
      f.value "--key-env"
      f.switch "--new"
      f.switch "--no-agent", key: :agent, set: false
      f.refuse "--all", "there is no --all"
    end
  end

  def parse(*argv, flags: self.flags, **defaults) = flags.parse(argv, defaults)

  it "reads switches, values in both forms, repeats and positionals in order" do
    result = parse("a", "-m", "hi", "--new", "--image", "x", "--image=y=z", "--key-env=K", "--no-agent", "b", images: [])

    expect(result.options).to eq(message: "hi", new: true, images: %w[x y=z], key_env: "K", agent: false)
    expect(result.args).to eq(%w[a b])
    expect([result.help, result.error]).to eq([false, nil])
  end

  it "keeps the defaults it was given unchanged" do
    defaults = { images: ["a"].freeze }.freeze
    expect(flags.parse(%w[--image b], defaults).options).to eq(images: %w[a b])
  end

  it "takes the next argument as the value, whatever it looks like, unless dash_values is off" do
    expect(parse("-m", "--new").options).to eq(message: "--new")
    strict = described_class.new(dash_values: false) { |f| f.value "--name" }
    expect(parse("--name", "-x", flags: strict).options).to eq(name: "-x")
    expect(parse("--name", "--x", flags: strict).error).to have_attributes(kind: :missing, arg: "--name")
  end

  it "stops at a help word, not at a value that looks like one" do
    expect(parse("a", "--help", "--bogus")).to have_attributes(help: true, error: nil, args: ["a"])
    expect(parse("-m", "-h")).to have_attributes(help: false, options: { message: "-h" })
  end

  it "stops at the first error, with its kind and the argument as given" do
    expect(parse("--bogus", "--all").error).to have_attributes(kind: :unknown, arg: "--bogus", message: "unknown option --bogus")
    expect(parse("--new=1").error).to have_attributes(kind: :unknown, arg: "--new=1")
    expect(parse("-").error).to have_attributes(kind: :unknown, arg: "-")
    expect(parse("--image").error).to have_attributes(kind: :missing, message: "--image needs a value")
    expect(parse("--all", "--bogus").error).to have_attributes(kind: :refused, message: "there is no --all")
  end

  it "takes dashed words as positionals outside flag_pattern, and refuses positionals when args is off" do
    loose = described_class.new(flag_pattern: /\A--/) { |f| f.switch "--force" }
    expect(parse("-h", "x", "--force", flags: loose)).to have_attributes(args: %w[-h x], options: { force: true })
    expect(parse("--nope", flags: loose).error).to have_attributes(kind: :unknown, arg: "--nope")
    closed = described_class.new(args: false) { |f| f.switch "help" }
    expect(parse("help", flags: closed).options).to eq(help: true)
    expect(parse("foo", flags: closed).error).to have_attributes(kind: :unknown, arg: "foo")
  end
end
