# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

require "samagotchi/web/token"

RSpec.describe Samagotchi::Web::Token do
  let(:root) { Dir.mktmpdir("web-token") }
  let(:path) { File.join(root, "samagotchi", "web-token") }

  after { FileUtils.remove_entry(root) }

  it "lives next to the sessions, in the state dir" do
    expect(described_class.path(env: { "XDG_STATE_HOME" => root })).to eq(File.join(root, "samagotchi", "web-token"))
  end

  it "makes a 43-character URL-safe token on first use, the file 0600 and a new folder 0700" do
    token = described_class.load_or_create(path)

    expect(token).to match(/\A[A-Za-z0-9_-]{43}\z/)
    expect(File.stat(path).mode & 0o777).to eq(0o600)
    expect(File.stat(File.dirname(path)).mode & 0o777).to eq(0o700)
    expect(Dir.children(File.dirname(path))).to eq(["web-token"])
  end

  it "keeps the token across starts" do
    token = described_class.load_or_create(path)

    expect(described_class.load_or_create(path)).to eq(token)
    expect(described_class.read(path)).to eq(token)
  end

  it "reads nothing when there is no file" do
    expect(described_class.read(path)).to be_nil
  end

  it "rotates to a new token, still 0600" do
    old = described_class.load_or_create(path)
    File.chmod(0o644, path)

    new = described_class.rotate(path)

    expect(new).not_to eq(old)
    expect(new.size).to eq(43)
    expect(described_class.read(path)).to eq(new)
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  describe Samagotchi::Web::Token::Source do
    it "sees a rotation at once, and nothing once the file is gone" do
      old = Samagotchi::Web::Token.load_or_create(path)
      source = described_class.new(path)
      expect(source.current).to eq(old)

      new = Samagotchi::Web::Token.rotate(path)
      expect(source.current).to eq(new)

      File.delete(path)
      expect(source.current).to be_nil
    end
  end
end
