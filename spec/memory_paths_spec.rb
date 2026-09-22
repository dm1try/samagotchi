# frozen_string_literal: true

require "samagotchi/memory_paths"
require "digest"

RSpec.describe Samagotchi::MemoryPaths do
  describe ".system_dir" do
    it "lives next to config.yml under XDG_CONFIG_HOME" do
      expect(described_class.system_dir(env: { "XDG_CONFIG_HOME" => "/xdg" })).to eq("/xdg/samagotchi/memories")
    end

    it "falls back to ~/.config when XDG_CONFIG_HOME is blank" do
      expect(described_class.system_dir(env: { "XDG_CONFIG_HOME" => " " }))
        .to eq(File.join(Dir.home, ".config", "samagotchi", "memories"))
    end

    it "reads ENV on every call, not once at load" do
      original = ENV["XDG_CONFIG_HOME"]
      ENV["XDG_CONFIG_HOME"] = "/first"
      first = described_class.system_dir
      ENV["XDG_CONFIG_HOME"] = "/second"
      expect([first, described_class.system_dir]).to eq(%w[/first/samagotchi/memories /second/samagotchi/memories])
    ensure
      ENV["XDG_CONFIG_HOME"] = original
    end
  end

  describe ".project_dir" do
    it "keys the folder by basename and MD5 of the working directory" do
      key = "repo_#{Digest::MD5.hexdigest("/src/repo")[0..7]}"
      expect(described_class.project_dir(env: { "XDG_CONFIG_HOME" => "/xdg" }, cwd: "/src/repo"))
        .to eq("/xdg/samagotchi/memories/projects/#{key}")
    end
  end

  describe ".bundles_dir" do
    it "sits inside the system memories dir" do
      expect(described_class.bundles_dir(env: { "XDG_CONFIG_HOME" => "/xdg" })).to eq("/xdg/samagotchi/memories/.bundles")
    end
  end
end
