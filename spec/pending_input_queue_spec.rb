# frozen_string_literal: true

require "samagotchi/pending_input_queue"

RSpec.describe Samagotchi::PendingInputQueue do
  subject(:queue) { described_class.new }

  it "starts empty" do
    expect(queue).to be_empty
    expect(queue.size).to eq(0)
    expect(queue.drain).to eq([])
  end

  it "drains messages in FIFO order" do
    queue.push("first")
    queue.push("second")
    queue.push("third")

    expect(queue.drain).to eq(["first", "second", "third"])
    expect(queue).to be_empty
  end

  it "drain empties the queue" do
    queue.push("only")

    queue.drain
    expect(queue.drain).to eq([])
    expect(queue.size).to eq(0)
  end

  it "ignores nil and empty messages" do
    queue.push(nil)
    queue.push("")

    expect(queue).to be_empty
    expect(queue.drain).to eq([])
  end

  it "is thread-safe under concurrent push and drain" do
    producers = 4.times.map do |i|
      Thread.new do
        50.times { |n| queue.push("msg-#{i}-#{n}") }
      end
    end

    drained = []
    consumer = Thread.new do
      drained.concat(queue.drain) until producers.all? { |t| !t.alive? } && queue.empty?
    end

    producers.each(&:join)
    consumer.join

    expect(drained.length).to eq(200)
    expect(drained.uniq.length).to eq(200)
  end
end
