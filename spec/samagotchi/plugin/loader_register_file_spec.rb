# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/plugin/loader"
require "samagotchi/commands/registry"
require "samagotchi/tools/registry"
require "samagotchi/hooks/registry"

# Plugin::Loader.register_file: build one plugin file and commit what it
# registered, with no install checks (what the test kit loads through).
RSpec.describe Samagotchi::Plugin::Loader, ".register_file" do
  let(:dir) { Dir.mktmpdir("register-file-") }
  let(:services) { Samagotchi::Plugin::Services.new }
  let(:registries) do
    Samagotchi::Plugin::Registries.new(commands: Samagotchi::Commands::Registry.new, tools: Samagotchi::Tools::Registry.new,
                                       hooks: Samagotchi::Hooks::Registry.new, services: services)
  end

  after { FileUtils.rm_rf(dir) }

  def plugin_file(source)
    File.join(dir, "plugin.rb").tap { |path| File.write(path, source) }
  end

  it "commits what #register staged and returns the Api" do
    file = plugin_file(<<~RUBY)
      class Plugin
        def initialize(settings) = @word = settings.fetch("word")
        def register(chi)
          chi.command("/hi", "says hi") { |_args, _ctx| @word }
          chi.on(:before_turn) { |event| event[:hit] = true }
        end
      end
    RUBY

    api = described_class.register_file("greeter", file, registries, settings: { "word" => "hello" })

    expect(api.counts).to include(commands: 1, hooks: 1)
    expect(registries.commands.lookup("/hi").handler.call("")).to eq("hello")
    event = {}
    registries.hooks.fire(:before_turn, event)
    expect(event[:hit]).to be true
  end

  it "raises a broken file's error, registers nothing and stops the services it started" do
    stopped = []
    file = plugin_file(<<~RUBY)
      class Plugin
        def register(chi)
          chi.command("/hi", "says hi") { |_args, _ctx| "hi" }
          chi.service(:server, eager: true) { |svc| svc.on_stop { STOPPED << :server }; :up }
          raise "halfway"
        end
      end
    RUBY
    stub_const("STOPPED", stopped)

    expect { described_class.register_file("broken", file, registries) }.to raise_error(RuntimeError, "halfway")
    expect(registries.commands.lookup("/hi")).to be_nil
    expect(registries.hooks.size).to eq(0)
    expect(stopped).to eq([:server])
  end

  it "evaluates the file in the given namespace" do
    file = plugin_file("class Plugin\n  def register(chi) = nil\nend\n")
    namespace = Module.new
    described_class.register_file("mine", file, registries, namespace: namespace)
    expect(namespace.const_defined?(:Plugin, false)).to be true
  end

  it "yields the built plugin and gives #register an instance of api_class" do
    file = plugin_file("class Plugin\n  def register(chi) = (@chi = chi)\n  attr_reader :chi\nend\n")
    recording = Class.new(Samagotchi::Plugin::Api)
    built = nil
    api = described_class.register_file("mine", file, registries, api_class: recording) { |plugin| built = plugin }
    expect(api).to be_a(recording)
    expect(built.chi).to be(api)
  end

  it "raises a syntax error" do
    file = plugin_file("class Plugin\n  def register(chi\nend\n")
    expect { described_class.register_file("syntax", file, registries) }.to raise_error(SyntaxError)
  end
end
