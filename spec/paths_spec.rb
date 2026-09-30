# frozen_string_literal: true

require "samagotchi/paths"
require "samagotchi/session"
require "samagotchi/log_path"

RSpec.describe Samagotchi::Paths do
  describe ".state_home" do
    it "is XDG_STATE_HOME when set, stripped" do
      expect(described_class.state_home(env: { "XDG_STATE_HOME" => " /xdg-state " })).to eq("/xdg-state")
    end

    it "falls back to ~/.local/state when XDG_STATE_HOME is unset or blank" do
      expect(described_class.state_home(env: {})).to eq(File.join(Dir.home, ".local", "state"))
      expect(described_class.state_home(env: { "XDG_STATE_HOME" => " " })).to eq(File.join(Dir.home, ".local", "state"))
    end

    it "reads ENV on every call" do
      expect(described_class.state_home).to eq(ENV.fetch("XDG_STATE_HOME"))
    end
  end

  describe ".state_dir" do
    it "is the samagotchi folder in the state home" do
      expect(described_class.state_dir(env: { "XDG_STATE_HOME" => "/s" })).to eq("/s/samagotchi")
    end
  end

  describe ".config_home" do
    it "is XDG_CONFIG_HOME when set, else ~/.config" do
      expect(described_class.config_home(env: { "XDG_CONFIG_HOME" => "/c" })).to eq("/c")
      expect(described_class.config_home(env: { "XDG_CONFIG_HOME" => "" })).to eq(File.expand_path("~/.config"))
    end
  end

  it "gives the same folders as the modules that use it" do
    env = { "XDG_STATE_HOME" => "/s", "XDG_CONFIG_HOME" => "/c" }
    expect(Samagotchi::Session.default_state_dir(env: env)).to eq("/s/samagotchi/sessions")
    expect(Samagotchi::LogPath.default_path(env: env)).to eq("/s/samagotchi/samagotchi.log")
    expect(Samagotchi::ConfigFile.config_dir(env: env)).to eq("/c/samagotchi")
  end
end
