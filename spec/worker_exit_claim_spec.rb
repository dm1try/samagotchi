# frozen_string_literal: true

require "spec_helper"
require "samagotchi/worker_exit_claim"
require "samagotchi/hold_stop"

# One exit at a time (Worker#exit_request): the kind being taken, the exit
# taken and the last stop-all's list, under one lock of its own, so a
# caller needs no outer lock to keep them consistent.
RSpec.describe Samagotchi::WorkerExitClaim do
  subject(:claim) { described_class.new }

  let(:leaving) { Samagotchi::WorkerIdleExit }
  let(:stopped) { Samagotchi::HoldStop::Stopped.new(reminders: ["r"], tasks: [], delegates: []) }

  it "gives the first claim to its request" do
    expect(claim.claim(:exit)).to be_nil
    expect(claim.taken?).to be(false)
    expect(claim.taken).to be_nil
  end

  it "answers a request of the kind already taken as accepted (Refused nil)" do
    claim.claim(:restart)
    claim.accept(by: "web:1", stop: false)

    expect(claim.claim(:restart)).to eq(described_class::Refused.new(value: nil))
    expect(claim.taken).to have_attributes(kind: :restart, by: "web:1", restart?: true, deletes?: false)
  end

  it "refuses another kind once taken, and any kind while being taken, as the one leaving" do
    claim.claim(:exit)
    expect(claim.claim(:exit)).to eq(described_class::Refused.new(value: leaving.leaving(:exit)))
    expect(claim.claim(:restart)).to eq(described_class::Refused.new(value: leaving.leaving(:exit)))

    claim.accept(by: "tui:1", stop: false)
    expect(claim.claim(:delete)).to eq(described_class::Refused.new(value: leaving.leaving(:exit)))
  end

  it "clears the claim and the taken exit on forget, so the next request claims" do
    claim.claim(:delete)
    claim.accept(by: "tui:1", stop: false)
    expect(claim).to have_attributes(taken?: true, deletes?: true, restart?: false)

    claim.forget

    expect(claim).to have_attributes(taken?: false, taken: nil, deletes?: false, restart?: false)
    expect(claim.claim(:restart)).to be_nil
  end

  it "releases a claim not taken yet, and keeps one taken" do
    claim.claim(:exit)
    claim.release
    expect(claim.claim(:restart)).to be_nil

    claim.accept(by: "web:1", stop: false)
    claim.release
    expect(claim.taken).to have_attributes(kind: :restart)
  end

  it "keeps the stop-all's list for a stop exit, even one from before a forget, and clears it for a plain one" do
    claim.claim(:exit)
    claim.stopped!(stopped)
    claim.forget
    expect(claim.stopped).to eq(stopped)

    claim.claim(:exit)
    claim.accept(by: "tui:1", stop: true)
    expect(claim.stopped).to eq(stopped)
    claim.forget

    claim.claim(:exit)
    claim.accept(by: "tui:1", stop: false)
    expect(claim.stopped).to be_nil
  end

  # What the event lock gives today by convention, with no outer lock:
  # every taken exit read is one whole value, the kind that claimed it.
  it "hands every reader one consistent taken exit while threads claim, accept and forget with no outer lock" do
    kinds = %i[exit delete restart]
    stop = false
    errors = Queue.new
    holders = Array.new(4) do |i|
      Thread.new do
        rng = Random.new(i)
        300.times do |n|
          kind = kinds.sample(random: rng)
          next Thread.pass if claim.claim(kind)

          if rng.rand < 0.7
            claim.accept(by: "#{kind}-#{i}-#{n}", stop: false)
            other = (kinds - [kind]).sample(random: rng)
            refused = claim.claim(other)
            errors << [:taken_not_refused, kind, other, refused] unless refused == described_class::Refused.new(value: leaving.leaving(kind))
          end
          Thread.pass
          claim.forget
        end
      end
    end
    readers = Array.new(3) do
      Thread.new do
        until stop
          taken = claim.taken
          next Thread.pass unless taken

          errors << [:by, taken] unless taken.by.start_with?("#{taken.kind}-")
          errors << [:restart, taken] unless taken.restart? == (taken.kind == :restart)
          errors << [:deletes, taken] unless taken.deletes? == (taken.kind == :delete)
        end
      end
    end

    holders.each { |thread| join!(thread, "a holder") }
    stop = true
    readers.each { |thread| join!(thread, "a reader") }

    expect(Array.new(errors.size) { errors.pop }).to eq([])
    expect(claim.taken?).to be(false)
  end
end
