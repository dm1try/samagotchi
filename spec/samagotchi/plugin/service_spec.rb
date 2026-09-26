# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plugin/service"

RSpec.describe Samagotchi::Plugin::Service do
  it "starts on first #value, once, and gives what its block returned" do
    starts = 0
    service = described_class.new("b:srv") { starts += 1; :client }
    expect(service.state).to eq(:idle)
    expect(service.value).to eq(:client)
    expect(service.value).to eq(:client)
    expect(starts).to eq(1)
    expect(service).to be_running
  end

  it "runs its on_stop callbacks newest first, once, and never starts again" do
    log = []
    service = described_class.new("b:srv") do |svc|
      svc.on_stop { log << :first }
      svc.on_stop { log << :second }
      :client
    end
    service.value
    service.stop
    service.stop
    expect(log).to eq(%i[second first])
    expect(service.state).to eq(:stopped)
    expect { service.value }.to raise_error(described_class::Stopped, /b:srv is stopped/)
  end

  it "stops a service that never started without running anything" do
    service = described_class.new("b:srv") { raise "never" }
    service.stop
    expect(service.state).to eq(:stopped)
  end

  it "stays idle when its block raises, after running the on_stop callbacks given so far, and tries again" do
    log = []
    tries = 0
    service = described_class.new("b:srv") do |svc|
      tries += 1
      svc.on_stop { log << tries }
      raise "spawn failed" if tries == 1

      :client
    end
    expect { service.value }.to raise_error(RuntimeError, "spawn failed")
    expect(log).to eq([1])
    expect(service.state).to eq(:idle)
    expect(service.value).to eq(:client)
  end

  it "logs a stop callback that raises, and the rest still run" do
    log = []
    service = described_class.new("b:srv") do |svc|
      svc.on_stop { log << :ran }
      svc.on_stop { raise "boom" }
      :client
    end
    service.value
    expect(Samagotchi::Log).to receive(:warn).with(:plugins, "service_stop_failed", hash_including(msg: "boom"))
    service.stop
    expect(log).to eq([:ran])
  end
end

RSpec.describe Samagotchi::Plugin::Services do
  it "stops its services newest first" do
    log = []
    services = described_class.new
    %w[a b c].each do |name|
      services.add(Samagotchi::Plugin::Service.new(name) { |svc| svc.on_stop { log << name } }).value
    end
    services.stop_all
    expect(log).to eq(%w[c b a])
  end
end
