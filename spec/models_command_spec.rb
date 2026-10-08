# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "fileutils"
require "spec_helper"
require "samagotchi/models_command"

# `chi models`: what --model takes, listed from every host within a bounded
# wait; the desktop helper's picker reads --format json.
RSpec.describe Samagotchi::ModelsCommand do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "default" => { host: "localhost", port: 8080 },
      "box" => { host: "box.test", port: 8081 }
    }, env: {})
  end
  let(:lists) { { "default" => %w[gemma-4 qwen3:8b], "box" => %w[big Qwen-Coder] } }
  let(:waits) { [] }

  def info(id) = Samagotchi::LLM::ModelInfo.new(id: id, context_window: nil, supports_tools: nil, raw: {})

  before do
    allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({ "small" => "box:big" })
    allow(registry).to receive(:list_all_models).and_wrap_original do |original, **kwargs|
      waits << kwargs
      lists.each do |host, ids|
        next allow(registry.entries[host].client).to receive(:list_models).and_raise("connection refused") if ids.nil?

        allow(registry.entries[host].client).to receive(:list_models).and_return(ids.map { |id| { "id" => id } })
      end
      original.call(**kwargs)
    end
  end

  def run(*argv, default_name: "gemma-4")
    described_class.new(argv, stdout: out, stderr: err, registry: registry, default_name: default_name).run
  end

  it "prints one name per line, the default first, then the aliases, and lists anew within 4 s" do
    expect(run).to eq(0)

    expect(out.string.lines.map(&:chomp)).to eq(["gemma-4", "default:qwen3:8b", "box:big", "box:Qwen-Coder", "small -> box:big"])
    expect(err.string).to eq("")
    expect(waits).to eq([{ force: true, wait: 4.0 }])
  end

  it "filters the names by a text, any case" do
    expect(run("QWEN")).to eq(0)

    expect(out.string.lines.map(&:chomp)).to eq(["default:qwen3:8b", "box:Qwen-Coder"])
  end

  it "prints the catalog as JSON with --format json and takes --timeout" do
    expect(run("--format", "json", "--timeout", "1.5", default_name: "small")).to eq(0)

    payload = JSON.parse(out.string)
    expect(payload).to include("default" => "box:big", "default_typed" => "small", "default_host" => "default", "warnings" => [],
                               "aliases" => [{ "name" => "small", "ref" => "box:big", "host" => "box" }])
    expect(payload["models"].map { |m| m["name"] }).to eq(%w[gemma-4 default:qwen3:8b box:big box:Qwen-Coder])
    expect(waits).to eq([{ force: true, wait: 1.5 }])
  end

  context "with ids declared under hosts.<name>.models" do
    let(:registry) do
      Samagotchi::HostRegistry.new(hosts_config: {
        "default" => { host: "localhost", port: 8080 },
        "box" => { host: "box.test", port: 8081, models: Samagotchi::HostModel.parse_map(%w[rr/x big], "box") }
      }, env: {})
    end

    it "prints them as plain names, first under their host; the JSON marks them configured" do
      expect(run).to eq(0)
      expect(out.string.lines.map(&:chomp))
        .to eq(["gemma-4", "default:qwen3:8b", "box:rr/x", "box:big", "box:Qwen-Coder", "small -> box:big"])

      out.truncate(0)
      out.rewind
      run("--format", "json")
      expect(JSON.parse(out.string)["models"].select { |m| m["configured"] }.map { |m| m["name"] })
        .to eq(%w[box:rr/x box:big])
    end
  end

  it "notes a failed host on stderr and still exits 0 when another host listed" do
    lists["box"] = nil

    expect(run).to eq(0)
    expect(out.string.lines.map(&:chomp)).to eq(["gemma-4", "default:qwen3:8b", "small -> box:big"])
    expect(err.string).to include("chi models: box: ")
  end

  it "exits 1 when no host listed, still printing the default (and the JSON)" do
    lists["box"] = nil
    lists["default"] = nil

    expect(run("--format", "json")).to eq(1)
    payload = JSON.parse(out.string)
    expect(payload["default"]).to eq("gemma-4")
    expect(payload["models"]).to eq([])
    expect(payload["warnings"].size).to eq(2)
  end

  it "exits 1 with the error as a warning when the listing itself fails" do
    allow(registry).to receive(:list_all_models).and_raise("no config")

    expect(run("--format", "json")).to eq(1)
    expect(JSON.parse(out.string)).to include("default" => "gemma-4", "models" => [], "warnings" => ["no config"])
  end

  it "exits 2 on a usage error" do
    expect(run("--format", "xml")).to eq(2)
    expect(run("--timeout", "0")).to eq(2)
    expect(run("--timeout", "soon")).to eq(2)
    expect(run("--bogus")).to eq(2)
    expect(err.string).to include("chi models: --format takes text or json")
    expect(waits).to eq([])
  end

  describe "as a process" do
    let(:tmp) { Dir.mktmpdir("chi-models") }
    let(:env) { isolated_chi_env(tmp) }

    after { FileUtils.remove_entry(tmp) }

    def write_config(text)
      FileUtils.mkdir_p(File.join(tmp, "config", "samagotchi"))
      File.write(File.join(tmp, "config", "samagotchi", "config.yml"), text)
    end

    it "prints the default alone and exits 1 when no host answers" do
      write_config("default:\n  model: spec-model\nhosts:\n  default:\n    host: 127.0.0.1\n    port: 1\n")

      out, err, status = run_chi("models", "--format", "json", "--timeout", "2", env: env, timeout: 20)

      expect(status.exitstatus).to eq(1), err
      payload = JSON.parse(out)
      expect(payload).to include("default" => "spec-model", "models" => [])
      expect(payload["warnings"].first).to start_with("default: ")
    end

    it "exits 2 on an unknown format" do
      _out, err, status = run_chi("models", "--format", "xml", env: env, timeout: 20)

      expect(status.exitstatus).to eq(2)
      expect(err).to include("Usage: chi models")
    end
  end
end
