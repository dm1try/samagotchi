# frozen_string_literal: true

require "samagotchi/guardrails"
require "samagotchi/guardrails/chi_dirs"
require "samagotchi/system_one/self_protect"

# chi's dir sets; what each surface answers with them is pinned in
# path_consistency_spec.rb.
RSpec.describe Samagotchi::Guardrails::ChiDirs do
  let(:state) { Samagotchi::Paths.state_dir }
  let(:config) { Samagotchi::ConfigFile.config_dir }

  it "is the set each surface named: ParentApprovals', Targets', SelfProtect's and ReviewPaths'" do
    expect(Samagotchi::Guardrails::ParentApprovals.chi_dirs).to eq(described_class.protected)
    expect(described_class.protected).to include(config, File.join(state, "guardrails"), File.join(state, "context"))
    expect(Samagotchi::SystemOne::SelfProtect.chi_dirs).to eq(described_class.self_protect)
    expect(described_class.self_protect).to include(Samagotchi::Guardrails::PathResolve.real(state))
    expect(Samagotchi::Guardrails::ReviewPaths.chi_dirs).to eq(described_class.review)
    expect(described_class.review).to eq([state, File.join(Samagotchi::Paths.config_home, "samagotchi")])
  end

  it "adds a hooks dir configured outside the config dir for review" do
    Dir.mktmpdir("chi-dirs") do |dir|
      with_config_home(File.join(dir, "config")) do
        config = File.join(dir, "config", "samagotchi")
        hooks = File.join(dir, "hooks")
        File.write(File.join(config, "config.yml"), "hooks:\n  hooks_dir: #{hooks}\n")
        expect(described_class.review).to eq([state, config, hooks])
        File.write(File.join(config, "config.yml"), "hooks:\n  hooks_dir: #{File.join(config, "my-hooks")}\n")
        expect(described_class.review).to eq([state, config])
      end
    end
  end

  it "adds the session repo's hooks dir for touches" do
    context = Samagotchi::Guardrails::Context.new(cwd: Dir.pwd)
    allow(context).to receive(:hooks_dir).with("/repo").and_return("/repo/.git/hooks")
    expect(described_class.touches(context, "/repo")).to eq([*described_class.protected, "/repo/.git/hooks"])
    expect(Samagotchi::Guardrails::Targets.chi_dirs(context, "/repo")).to eq(described_class.touches(context, "/repo"))
  end
end
