# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "samagotchi/testing"

# The bundle test kit's side of chi.prompt_section and chi.prompt_changed!.
RSpec.describe Samagotchi::Testing::Bundle, "prompt sections" do
  let(:dir) { Dir.mktmpdir("kit-prompt-") }
  let(:loaded) { [] }

  after do
    loaded.each(&:shutdown)
    FileUtils.rm_rf(dir)
  end

  def load_plugin(source, **)
    File.write(File.join(dir, "plugin.rb"), source)
    File.write(File.join(dir, "manifest.yml"),
               YAML.dump({ "name" => "tone", "version" => "1.0.0", "files" => {},
                           "plugin" => { "file" => "plugin.rb", "sha256" => "" } }))
    described_class.load(dir, **).tap { |bundle| loaded << bundle }
  end

  it "runs the sections as a prompt build does and counts chi.prompt_changed!" do
    bundle = load_plugin(<<~RUBY)
      class Plugin
        def initialize(_settings) = @style = nil

        def register(chi)
          chi.prompt_section("tone") { |ctx| @style && "\#{@style} for \#{ctx.model_key}" }
          chi.command("/tone", "sets the tone") do |args, _ctx|
            @style = args
            chi.prompt_changed!
            "tone: \#{args}"
          end
        end
      end
    RUBY

    expect(bundle.prompt_text).to be_nil
    bundle.command("/tone concise")
    expect(bundle.prompt_changes).to eq(1)
    expect(bundle.prompt_text).to eq("From tone (tone):\nconcise for model")
    expect(bundle.prompt_sections.map(&:to_stats)).to eq([{ bundle: "tone", name: "tone" }])
    expect(bundle.declarations.map(&:name)).to include(:prompt_section)
  end
end
