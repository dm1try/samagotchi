# frozen_string_literal: true

require "spec_helper"
require "samagotchi/memory_bundle/asset_state"
require_relative "file_state_corpus/support"
require_relative "file_state_corpus/assets"

# AssetState.of over every rule, plugin and script case's starting tree
# (asset_cases.yml), both record shapes: the state its case names, against
# the case's source and against none (uninstall, status).
RSpec.describe Samagotchi::MemoryBundle::AssetState do
  before(:all) { @sandbox = BundleStateCorpus::AssetSandbox.new }
  after(:all) { @sandbox&.cleanup }

  # A dev link to the source's bytes is unchanged: a link only stands apart
  # when it points at other bytes than the source's.
  def with_source = { "new" => :new, "unchanged" => :unchanged, "pristine" => :pristine, "edited_sha" => :edited,
                      "edited_no_sha" => :edited, "dev_link" => :unchanged, "dropped_pristine" => :dropped_pristine,
                      "dropped_edited" => :dropped_edited }

  # No source: what is there is dropped (a new one isn't there at all).
  def source_less = { "new" => nil, "unchanged" => :dropped_pristine, "pristine" => :dropped_pristine,
                      "edited_sha" => :dropped_edited, "edited_no_sha" => :dropped_edited, "dev_link" => :linked,
                      "dropped_pristine" => :dropped_pristine, "dropped_edited" => :dropped_edited }

  def asset_cases = BundleStateCorpus.asset_cases.reject { |kase| kase.asset == "hook" }

  def disagreements(want, source:)
    asset_cases.flat_map do |kase|
      BundleStateCorpus::SHAPES.filter_map do |shape|
        found = BundleStateCorpus::AssetStates.state(@sandbox, kase, shape, source: source)&.state
        "#{kase.id} (#{shape}): #{found.inspect}, want #{want.fetch(kase.state).inspect}" unless found == want.fetch(kase.state)
      end
    end
  end

  it "gives each case the state it names, in both record shapes" do
    expect(disagreements(with_source, source: true)).to eq([])
  end

  it "gives each case its source-less state" do
    expect(disagreements(source_less, source: false)).to eq([])
  end

  it "is edited exactly when the trash would keep a copy (Trash.edit?)" do
    got = asset_cases.filter_map do |kase|
      asset = BundleStateCorpus::AssetStates.state(@sandbox, kase, "0.155")
      next unless asset

      trash = Samagotchi::MemoryBundle::Trash.edit?(asset.path, recorded: asset.recorded, incoming: asset.incoming)
      "#{kase.id}: edited? #{asset.edited?}, Trash.edit? #{trash}" unless asset.edited? == trash
    end
    expect(got).to eq([])
  end

  describe "outside the corpus" do
    around { |example| Dir.mktmpdir { |dir| @dir = dir and example.run } }

    def write(name, text)
      path = File.join(@dir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
      path
    end

    def sha(text) = "sha256:#{Digest::SHA256.hexdigest(text)}"

    it "calls a link to other bytes than the source's linked, and never edited" do
      old = write("old/r.yml", "# old\n")
      incoming = write("src/r.yml", "# new\n")
      FileUtils.mkdir_p(File.join(@dir, "guardrails"))
      File.symlink(old, File.join(@dir, "guardrails", "r.yml"))
      asset = described_class.of(File.join(@dir, "guardrails", "r.yml"), kind_of_file: :rule, recorded: "dev", incoming: incoming)
      expect([asset.state, asset.edited?, asset.label]).to eq([:linked, false, "guardrails/r.yml"])
    end

    it "calls a broken link new when the source has the file, missing when not" do
      FileUtils.mkdir_p(File.join(@dir, "scripts"))
      File.symlink(File.join(@dir, "gone.sh"), File.join(@dir, "scripts", "s.sh"))
      incoming = write("src/s.sh", "# s\n")
      path = File.join(@dir, "scripts", "s.sh")
      expect(described_class.of(path, kind_of_file: :script, incoming: incoming).state).to eq(:new)
      expect(described_class.of(path, kind_of_file: :script, recorded: sha("# s\n")).state).to eq(:missing)
    end

    it "lists every file of the folder, at any depth, the incoming and the recorded ones, by name" do
      write("plugin/plugin.rb", "# p\n")
      write("plugin/lib/extra.rb", "# x\n")
      incoming = write("src/plugin.rb", "# p2\n")
      states = described_class.in(File.join(@dir, "plugin"), kind_of_file: :plugin,
                                                              recorded: { "plugin.rb" => sha("# p\n"), "gone.rb" => sha("# g\n") },
                                                              incoming: { "plugin.rb" => incoming, "new.rb" => incoming })
      expect(states.map { |asset| [asset.name, asset.state] })
        .to eq([["gone.rb", :missing], ["lib/extra.rb", :dropped_edited], ["new.rb", :new], ["plugin.rb", :pristine]])
    end

    it "reads nothing in a linked folder" do
      write("real/r.yml", "# r\n")
      File.symlink(File.join(@dir, "real"), File.join(@dir, "guardrails"))
      expect(described_class.in(File.join(@dir, "guardrails"), kind_of_file: :rule)).to eq([])
    end
  end
end
