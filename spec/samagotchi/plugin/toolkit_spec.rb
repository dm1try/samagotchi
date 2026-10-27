# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/plugin/api"
require "samagotchi/plugin/loader"
require "support/test_kernel"

# A plugin's toolkits (chi.toolkit) and its ctx.toolkit / ctx.use_toolkit.
RSpec.describe "Plugin toolkits" do
  describe "chi.toolkit" do
    let(:kits) { [] }
    let(:registries) { Samagotchi::Plugin::Registries.new(commands: nil, tools: nil, hooks: nil, toolkits: kits) }

    def api(bundle = "mine") = Samagotchi::Plugin::Api.new(bundle: bundle, label: "plugin.rb (bundle #{bundle})", registries: registries)

    it "declares a toolkit on a base when the plugin's register returns" do
      chi = api
      chi.toolkit("audit", base: "lean", add: ["delegate"], remove: ["web_fetch"])
      expect(kits).to be_empty
      chi.commit!
      expect(kits).to eq([Samagotchi::Toolkit::Kit.new(name: "audit", base: "lean", add: ["delegate"], remove: ["web_fetch"],
                                                       source: "mine")])
      expect(chi.counts[:toolkits]).to eq(1)
    end

    it "declares a toolkit with a prompt text; one that isn't text or is too long is a load error" do
      chi = api
      chi.toolkit("coding", base: "child", prompt: "- Be concise\n")
      chi.commit!
      expect(kits.last).to eq(Samagotchi::Toolkit::Kit.new(name: "coding", base: "child", prompt: "- Be concise", source: "mine"))
      expect(kits.last.prompt).to eq("- Be concise")
      expect { api.toolkit("odd", base: "lean", prompt: :concise) }.to raise_error(ArgumentError, "toolkit odd: prompt must be text")
      expect { api.toolkit("long", base: "lean", prompt: "x" * 2001) }
        .to raise_error(ArgumentError, "toolkit long: prompt is over 2000 characters")
    end

    it "accepts source group names and globs without changing inherited defaults" do
      chi = api
      chi.toolkit("web", base: "lean", groups: %w[chrome db* chrome])
      chi.toolkit("all", base: "web", groups: :all)
      chi.commit!

      expect(kits.map(&:groups)).to eq([%w[chrome db*], :all])
    end

    it "refuses groups that aren't a name or a list (a map) like a bad prompt" do
      expect { api.toolkit("odd", base: "lean", groups: { "chrome" => true }) }
        .to raise_error(ArgumentError, "toolkit odd: groups must be a list of group names or globs")
      expect { api.toolkit("odd", base: "lean", groups: [{ "chrome" => true }]) }
        .to raise_error(ArgumentError, "toolkit odd: groups must be a list of group names or globs")
    end

    it "refuses chi's own names, another bundle's, a twice-declared one and a bad name" do
      expect { api.toolkit("lean", base: "full") }.to raise_error(ArgumentError, "toolkit lean is chi's own")
      first = api("other")
      first.toolkit("audit", base: "lean")
      first.commit!
      expect { api.toolkit("audit", base: "lean") }.to raise_error(ArgumentError, "toolkit audit is already declared (other)")
      twice = api
      twice.toolkit("x", base: "lean")
      expect { twice.toolkit("x", base: "lean") }.to raise_error(ArgumentError, "toolkit x is declared twice")
      expect { api.toolkit("Bad Name", base: "lean") }.to raise_error(ArgumentError, /must be a-z/)
    end
  end

  describe "ctx.use_toolkit (Engine#use_toolkit)" do
    let(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel, profile: "gemma4") }
    let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd) }
    let(:ctx) do
      Samagotchi::Plugin::Context.new(bundle: "mine", label: "plugin.rb (bundle mine)", settings: {}, host: engine.send(:plugin_host))
    end
    let(:events) { [] }

    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      engine.session = session
      allow(engine).to receive(:announce_or_hold) { |event| events << event }
    end

    it "stages a known toolkit before the first model reply, saved and announced with the chip's summary" do
      expect(ctx.toolkit).to eq("full")
      expect(ctx.use_toolkit("lean")).to be(true)
      expect(ctx.toolkit).to eq("lean")
      expect(Samagotchi::Session.load(session.id).toolkit).to eq(Samagotchi::Toolkit.new(name: "lean"))
      expect(events.last).to include(type: :hook_notice, hook: "toolkit", text: "toolkit: lean from the next turn's start")
      expect(events.last[:toolkit]).to include(name: "lean", label: "lean")
    end

    it "reads the tools the next turn declares" do
      expect(ctx.declared_tools).to include("delegate")
      session.toolkit = Samagotchi::Toolkit.new(name: "full", remove: ["delegate"])
      expect(ctx.declared_tools).not_to include("delegate")
      expect(ctx.declared_tools).to include("send_note")
    end

    it "refuses after a model reply and while a turn runs, and an unknown name raises" do
      session.messages << { role: "model", content: "hi" }
      expect(ctx.use_toolkit("lean")).to be(false)
      session.messages.clear
      allow(engine).to receive(:turn_running?).and_return(true)
      expect(ctx.use_toolkit("lean")).to be(false)
      expect(session.toolkit).to be_nil
      expect { ctx.use_toolkit("nope") }.to raise_error(ArgumentError, "no toolkit named nope")
    end
  end
end
