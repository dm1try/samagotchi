# frozen_string_literal: true

require "tmpdir"
require "support/hard_link"

RSpec.describe HardLink do
  around { |example| Dir.mktmpdir("hard-link") { |dir| @dir = dir and example.run } }

  let(:source) { File.join(@dir, "a.txt").tap { |path| File.write(path, "x") } }
  let(:link) { File.join(@dir, "hard") }

  it "links the file itself on one device" do
    hard_link(source, link)

    expect(File.identical?(source, link)).to be(true)
  end

  it "links a copy beside the target across devices" do
    allow(File).to receive(:link).and_wrap_original do |original, from, to|
      raise Errno::EXDEV, to if from == source

      original.call(from, to)
    end
    hard_link(source, link)

    expect([File.read(link), File.stat(link).nlink]).to eq(["x", 2])
    expect(File.identical?(source, link)).to be(false)
  end
end
