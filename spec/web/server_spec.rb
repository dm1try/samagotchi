# frozen_string_literal: true

require "stringio"
require "samagotchi/web/server"

RSpec.describe Samagotchi::Web::Server::Log do
  let(:out) { StringIO.new }
  let(:log) { described_class.new(out, WEBrick::Log::WARN) }

  # Raised, as WEBrick hands them over: its format joins the backtrace.
  def raised(klass, msg = "x")
    raise klass, msg
  rescue klass => e
    e
  end

  it "drops a peer closing the connection" do
    [Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED].each { |klass| log.error(raised(klass)) }

    expect(out.string).to eq("")
  end

  it "keeps real errors and messages" do
    log.error(raised(RuntimeError, "boom"))
    log.error("bad request line")

    expect(out.string).to include("ERROR RuntimeError: boom").and include("ERROR bad request line")
  end
end
