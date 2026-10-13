# frozen_string_literal: true

require "samagotchi/plugin/loader"
require "samagotchi/plugin/api"
require "samagotchi/commands/registry"
require "samagotchi/tools/registry"

RSpec.describe "Samagotchi::Plugin::Api#annotation" do
  let(:commands) { Samagotchi::Commands::Registry.new }
  let(:registries) { Samagotchi::Plugin::Registries.new(commands: commands, tools: Samagotchi::Tools::Registry.new, hooks: nil) }
  let(:api) { Samagotchi::Plugin::Api.new(bundle: "peer", label: "plugin.rb (bundle peer)", registries: registries) }

  def listed(name) = commands.listing.find { |item| item[:name] == name }

  it "puts the annotation on its command's listing, the default template and fill" do
    api.annotation "Confirm with Claude", command: "/claude validate"
    api.command("/claude", "ask Claude") { |_args, _ctx| nil }
    api.commit!

    expect(listed("/claude")[:annotations])
      .to eq([{ label: "Confirm with Claude", line: "/claude validate", template: "{quote}", send: false }])
  end

  it "takes a template and send: true, and keeps the order they were declared in" do
    api.command("/foo", "foo") { |_args, _ctx| nil }
    api.annotation " Ask ", command: " /foo ", template: "{source}: {text}", send: true
    api.annotation "Again", command: "/foo again"
    api.commit!

    expect(listed("/foo")[:annotations]).to eq(
      [{ label: "Ask", line: "/foo", template: "{source}: {text}", send: true },
       { label: "Again", line: "/foo again", template: "{quote}", send: false }]
    )
  end

  it "leaves the annotations key out of a listing without any" do
    api.command("/foo", "foo") { |_args, _ctx| nil }
    api.commit!

    expect(listed("/foo")).not_to have_key(:annotations)
  end

  it "refuses a bad label, a line that isn't a /name, a blank template and a sixth annotation" do
    expect { api.annotation "", command: "/foo" }.to raise_error(ArgumentError, /label/)
    expect { api.annotation "x" * 41, command: "/foo" }.to raise_error(ArgumentError, /label/)
    expect { api.annotation "Go", command: "foo bar" }.to raise_error(ArgumentError, %r{/name})
    expect { api.annotation "Go", command: "/foo", template: " " }.to raise_error(ArgumentError, /template/)
    5.times { |i| api.annotation "A#{i}", command: "/foo" }
    expect { api.annotation "A5", command: "/foo" }.to raise_error(ArgumentError, /at most 5/)
  end

  it "fails the commit, registering nothing, for a command the plugin doesn't register" do
    api.command("/foo", "foo") { |_args, _ctx| nil }
    api.annotation "Go", command: "/bar now"

    expect { api.commit! }.to raise_error(ArgumentError, %r{/bar is not a command this plugin registers})
    expect(commands.entries).to be_empty
  end

  it "fails for another plugin's command" do
    commands.register("/other", "theirs", source: "other-bundle")
    api.command("/foo", "foo") { |_args, _ctx| nil }
    api.annotation "Go", command: "/other"

    expect { api.commit! }.to raise_error(ArgumentError, %r{/other is not a command this plugin registers})
    expect(commands.entries.map(&:name)).to eq(["/other"])
  end
end
