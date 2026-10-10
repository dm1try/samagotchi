# frozen_string_literal: true

require "spec_helper"
require "samagotchi/bootstrap/config_writer"
require "samagotchi/host_registry"

RSpec.describe Samagotchi::Bootstrap::ConfigWriter do
  let(:dir) { Dir.mktmpdir("bootstrap-writer") }
  let(:path) { File.join(dir, "samagotchi", "config.yml") }
  let(:now) { Time.utc(2026, 9, 29, 12, 0, 0) }
  let(:env) { {} }
  let(:writer) { described_class.new(path: path, env: env, now: -> { now }) }
  let(:lan) { { "host" => "192.168.1.29", "port" => 8081 } }

  after { FileUtils.rm_rf(dir) }

  def existing(text)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, text)
  end

  def parsed = YAML.safe_load_file(path)
  def hosts = Samagotchi::ConfigFile.hosts_config(env: {}, path: path)
  def backups = Dir[File.join(File.dirname(File.realpath(path)), "config.yml.bak-*")].sort

  describe ".derived_name" do
    it "names localhost local, an IP lan and a domain by its second-level label" do
      expect(%w[localhost 127.0.0.1 ::1 192.168.1.29 openrouter.ai api.openai.com gpu-box].map { |h| described_class.derived_name(h) })
        .to eq(%w[local local local lan openrouter openai gpu-box])
    end
  end

  describe "a new file" do
    it "writes a commented config with a host-qualified, quoted default.model" do
      outcome = writer.write(name: "lan", fields: lan, model: "ornith-ai/Ornith-1.5:Q4_K_M")

      expect(outcome.kind).to eq(:new)
      expect(File.read(path)).to eq(<<~YAML)
        # Written by chi bootstrap on 2026-09-29; see docs/configuration.md
        default:
          model: "lan:ornith-ai/Ornith-1.5:Q4_K_M"
        hosts:
          lan:
            host: "192.168.1.29"
            port: 8081
        # More settings: docs/configuration.md#all-settings
      YAML
      expect(parsed.dig("default", "model")).to eq("lan:ornith-ai/Ornith-1.5:Q4_K_M")
      expect(hosts["lan"]).to have_attributes(host: "192.168.1.29", port: 8081, api: nil)
    end

    it "writes nothing on a dry run" do
      outcome = writer.write(name: "lan", fields: lan, model: "m", dry_run: true)

      expect(outcome.kind).to eq(:dry_run)
      expect(outcome.text).to include("hosts:\n  lan:\n")
      expect(File.exist?(path)).to be(false)
    end

    it "loads without config warnings" do
      writer.write(name: "splash", fields: { "url" => "https://x.example/api/v1", "api" => "openai", "api_key_env" => "X_KEY" },
                   model: "m")

      expect(Samagotchi::Config.validate_yaml_sections(parsed)).to be_empty
    end
  end

  describe "an existing file" do
    it "inserts at the end of a 4-space hosts: block, keeping every other byte" do
      original = <<~YAML
        # my settings
        default:
          model: "main:qwen"   # the usual

        hosts:
            # the workstation
            main:
                host: "10.0.0.2"
                port: 8080

        # recap goes to the small box
        recap:
          host: main
      YAML
      existing(original)

      outcome = writer.write(name: "lan", fields: lan, model: "m")

      expect(outcome).to have_attributes(kind: :appended, default_model: nil, model_hint: nil)
      expect(File.read(path)).to eq(original.sub("        port: 8080\n",
                                                 "        port: 8080\n    lan:\n        host: \"192.168.1.29\"\n        port: 8081\n"))
      expect(hosts.keys).to eq(%w[main lan])
      expect(File.read(outcome.backup)).to eq(original)
      expect(outcome.backup).to end_with("config.yml.bak-20260929T120000Z")
    end

    it "keeps an entry's own trailing comments with it and the next section's comments below the insert" do
      original = "hosts:\n  main:\n    host: a\n    # port: 9000\n# --- models ---\n\nmodels: {}\n"
      existing(original)

      writer.write(name: "lan", fields: lan, model: "m")

      expect(File.read(path)).to eq("hosts:\n  main:\n    host: a\n    # port: 9000\n  lan:\n    host: \"192.168.1.29\"\n    " \
                                    "port: 8081\n# --- models ---\n\nmodels: {}\ndefault:\n  model: \"lan:m\"\n")
    end

    it "inserts into an all-commented hosts: block" do
      existing("hosts:\n  # main:\n  #   host: a\n")

      writer.write(name: "lan", fields: lan, model: "m")

      expect(parsed["hosts"]).to eq("lan" => lan)
      expect(parsed.dig("default", "model")).to eq("lan:m")
    end

    it "copies a server: route into a `default` entry first, so bare models still go there" do
      existing("server:\n  host: box.lan\n  port: 9090\ndefault:\n  model: qwen\n")

      outcome = writer.write(name: "lan", fields: lan, model: "m")

      expect(outcome.kind).to eq(:appended)
      expect(File.read(path)).to end_with("hosts:\n  default:\n    host: \"box.lan\"\n    port: 9090\n  lan:\n    " \
                                          "host: \"192.168.1.29\"\n    port: 8081\n")
      registry = Samagotchi::HostRegistry.new(hosts_config: hosts)
      expect(registry.default_entry).to have_attributes(name: "default", host: "box.lan", port: 9090)
    end

    it "says a host at the server: address is already there, and writes nothing" do
      existing("server:\n  host: 192.168.1.29\n  port: 8081\n")

      outcome = writer.write(name: "lan", fields: lan, model: "m")

      expect(outcome).to have_attributes(kind: :exists, existing: "default")
      expect(backups).to be_empty
    end

    it "keeps CRLF line endings and adds a missing final newline" do
      existing("hosts:\r\n  main:\r\n    host: a\r\ndefault:\r\n  model: main:x")

      writer.write(name: "lan", fields: lan, model: "m")

      expect(File.binread(path)).to eq("hosts:\r\n  main:\r\n    host: a\r\n  lan:\r\n    host: \"192.168.1.29\"\r\n    " \
                                       "port: 8081\r\ndefault:\r\n  model: main:x\r\n")
    end

    it "writes through a symlink, which stays a symlink" do
      real = File.join(dir, "dotfiles", "chi.yml")
      FileUtils.mkdir_p(File.dirname(real))
      File.write(real, "hosts:\n  main:\n    host: a\n")
      FileUtils.mkdir_p(File.dirname(path))
      File.symlink(real, path)

      writer.write(name: "lan", fields: lan, model: "m")

      expect(File.symlink?(path)).to be(true)
      expect(YAML.safe_load_file(real)["hosts"].keys).to eq(%w[main lan])
      expect(Dir[File.join(dir, "dotfiles", "chi.yml.bak-*")].size).to eq(1)
    end

    it "gives a flow-style hosts: or anchors a snippet to paste instead" do
      ["hosts: {main: {host: a}}\n", "base: &b\n  host: a\nhosts:\n  main: *b\n", "x: &a 1\nhosts:\n  main:\n    host: a\n"].each do |text|
        existing(text)
        outcome = described_class.new(path: path, env: env, now: -> { now }).write(name: "lan", fields: lan, model: "m")

        expect(outcome.kind).to eq(:snippet)
        expect(outcome.text).to eq("hosts:\n  lan:\n    host: \"192.168.1.29\"\n    port: 8081\n")
        expect(File.read(path)).to eq(text)
      end
    end

    it "keeps an earlier backup on a second run" do
      existing("hosts:\n  main:\n    host: a\n")
      writer.write(name: "lan", fields: lan, model: "m")
      described_class.new(path: path, env: env, now: -> { now })
                     .write(name: "cloud", fields: { "url" => "https://x.example/v1", "api" => "openai" }, model: "m")

      expect(backups.map { |b| File.basename(b) }).to eq(%w[config.yml.bak-20260929T120000Z config.yml.bak-20260929T120000Z-2])
      expect(parsed["hosts"].keys).to eq(%w[main lan cloud])
    end

    it "prints the default.model line when default: has no model" do
      existing("default:\n  input: hi\nhosts:\n  main:\n    host: a\n")

      outcome = writer.write(name: "lan", fields: lan, model: "m")

      expect(outcome.model_hint).to include('model: "lan:m"')
      expect(parsed["default"]).to eq("input" => "hi")
    end

    context "with SAMAGOTCHI_HOSTS_JSON in the environment (a worker's)" do
      let(:env) { { "SAMAGOTCHI_HOSTS_JSON" => JSON.generate("other" => { "host" => "x" }) } }

      it "checks the file's own hosts" do
        existing("hosts:\n  main:\n    host: a\n")

        expect(writer.write(name: "lan", fields: lan, model: "m").kind).to eq(:appended)
      end
    end

    it "puts the backup back when the check fails" do
      original = "hosts:\n  main:\n    host: a\n"
      existing(original)
      allow(Samagotchi::ConfigFile).to receive(:hosts_config).and_return({})

      outcome = writer.write(name: "lan", fields: lan, model: "m")

      expect(outcome.kind).to eq(:failed)
      expect(File.read(path)).to eq(original)
      expect(outcome.text).to start_with("hosts:\n  lan:\n")
    end
  end

  describe "#host_name" do
    it "suffixes a taken name or one that is a model id's prefix" do
      existing("hosts:\n  lan:\n    host: a\n  openai:\n    host: b\n")

      expect(writer.host_name("lan")).to eq("lan-2")
      expect(writer.host_name("qwen3", model_ids: ["qwen3:8b", "openai/gpt-x"])).to eq("qwen3-2")
      # Only ':' names a host: an org/model id leaves the name free.
      expect(writer.host_name("openrouter", model_ids: ["openrouter/auto"])).to eq("openrouter")
      expect(writer.host_name("fresh")).to eq("fresh")
    end

    it "takes --name as given, when it is free and well-formed" do
      existing("hosts:\n  lan:\n    host: a\n")

      expect(writer.host_name("x", requested: "box")).to eq("box")
      expect { writer.host_name("x", requested: "lan") }.to raise_error(described_class::Error, /already has a host named 'lan'/)
      expect { writer.host_name("x", requested: "no way") }.to raise_error(described_class::Error, /--name must match/)
    end
  end

  describe "#duplicate_of" do
    it "matches host+port entries and url entries" do
      existing("hosts:\n  main:\n    host: 192.168.1.29\n    port: 8081\n  or:\n    url: https://openrouter.ai/api/v1/\n    api: openai\n")

      expect(writer.duplicate_of(lan)).to eq("main")
      expect(writer.duplicate_of("url" => "https://openrouter.ai/api/v1", "api" => "openai")).to eq("or")
      expect(writer.duplicate_of("host" => "192.168.1.29", "port" => 8082, "api" => "openai")).to be_nil
    end
  end
end
