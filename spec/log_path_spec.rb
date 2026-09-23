# frozen_string_literal: true

require "samagotchi/log_path"

RSpec.describe Samagotchi::LogPath do
  after { Samagotchi::Config.set_cli_overrides({}) }

  describe ".resolve" do
    it "defaults to samagotchi.log under XDG_STATE_HOME, not the gem or checkout" do
      expect(described_class.resolve(env: { "XDG_STATE_HOME" => "/xdg-state" })).to eq("/xdg-state/samagotchi/samagotchi.log")
    end

    it "falls back to ~/.local/state when XDG_STATE_HOME is blank" do
      expect(described_class.resolve(env: { "XDG_STATE_HOME" => " " }))
        .to eq(File.join(Dir.home, ".local", "state", "samagotchi", "samagotchi.log"))
    end

    it "takes log.file, expanding ~ and relative paths" do
      Samagotchi::Config.set_cli_overrides("log.file" => "~/chi.log")
      expect(described_class.resolve).to eq(File.join(Dir.home, "chi.log"))

      Samagotchi::Config.set_cli_overrides("log.file" => "logs/chi.log")
      expect(described_class.resolve).to eq(File.join(Dir.pwd, "logs", "chi.log"))
    end

    it "is nil when log.disable is set, even with log.file" do
      Samagotchi::Config.set_cli_overrides("log.disable" => true, "log.file" => "/tmp/chi.log")
      expect(described_class.resolve).to be_nil
    end
  end
end
