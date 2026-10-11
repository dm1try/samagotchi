# frozen_string_literal: true

require "pp"
require "samagotchi/redacted_inspect"
require "samagotchi/context_command"
require "samagotchi/bootstrap_command"
require "samagotchi/broadcast_command"
require "samagotchi/gem_update"
require "samagotchi/installed_versions"
require "samagotchi/bootstrap/probe"
require "samagotchi/bootstrap/config_writer"
require "samagotchi/guardrails/shell_paths"
require "samagotchi/desktop/macos"
require "samagotchi/web/token"

RSpec.describe Samagotchi::RedactedInspect do
  # A real (named) class so its #inspect names itself; an anonymous class's
  # name is nil. Built in example scope, where stub_const is available.
  let(:holder_class) do
    stub_const("RedactedHolder", Class.new do
      include Samagotchi::RedactedInspect

      def initialize
        @name = "x"
        @env = { "OPENAI_API_KEY" => "sk-SECRET" }
        @token = "tok-SECRET"
      end
    end)
  end

  let(:holder) { holder_class.new }

  it "names the class and each non-redacted ivar with its own inspect" do
    expect(holder.inspect).to start_with("#<RedactedHolder")
    expect(holder.inspect).to include("@name=\"x\"")
  end

  it "never shows the redacted ivars, only [redacted]" do
    [holder.inspect, holder.pretty_inspect, [holder].inspect].each do |text|
      expect(text).to include("[redacted]")
      expect(text).not_to include("sk-SECRET")
      expect(text).not_to include("tok-SECRET")
    end
  end

  # Every class that holds the environment or the web token shares this
  # module, so inspecting any of them can no longer print the keys.
  redacted_classes = [
    Samagotchi::ContextCommand,
    Samagotchi::BootstrapCommand,
    Samagotchi::BroadcastCommand,
    Samagotchi::GemUpdate,
    Samagotchi::InstalledVersions,
    Samagotchi::Bootstrap::Probe,
    Samagotchi::Bootstrap::ConfigWriter,
    Samagotchi::Guardrails::ShellPaths::Walk,
    Samagotchi::Desktop::MacOS,
    Samagotchi::Web::Token::Source
  ]

  it "is included by every class that holds the environment or the token" do
    redacted_classes.each do |klass|
      expect(klass.ancestors).to include(described_class)
    end
  end
end
