# frozen_string_literal: true

require "yaml"
require "samagotchi/config"

RSpec.describe "Samagotchi::Config.validate_yaml_sections" do
  def problems(yaml)
    Samagotchi::Config.validate_yaml_sections(YAML.safe_load(yaml))
  end

  it "takes every config-exposed registry entry as written, with no second list to update" do
    data = Samagotchi::Config.all_entries.select(&:config_exposed?).each_with_object({}) do |entry, acc|
      *section, leaf = entry.yaml_path
      section.reduce(acc) { |node, seg| node[seg] ||= {} }[leaf] = "x"
    end
    expect(Samagotchi::Config.validate_yaml_sections(data)).to eq([])
  end

  it "warns about an unknown key, with a close known key as a suggestion" do
    expect(problems(<<~YAML)).to eq([
      default: {modle: m}
      bogus: 1
      servr: {port: 9}
      port: 8080
    YAML
      "config: unknown key 'default.modle' (did you mean 'default.model'?)",
      "config: unknown key 'bogus'",
      "config: unknown key 'servr' (did you mean 'server'?)",
      "config: unknown key 'port' (did you mean 'server.port' or 'web.port'?)"
    ])
  end

  it "keeps the free-form maps silent and checks host and model entries against the keys their readers take" do
    expect(problems(<<~YAML)).to eq(["config: unknown key 'hosts.other.hots' (did you mean 'hosts.other.host'?)"])
      hosts:
        box: {url: "http://h:1", api: openai, api_key_env: K, vision: true, first_token_timeout: 0}
        other: {hots: h}
      models: {Any-Model: {profile: qwen36, vision: false}}
      model_aliases: {small: any-model}
      hooks: {hooks_dir: ~/h, before_turn: [{path: a.rb}]}
      bundles: {known-names: {mode: reject}}
      memories: [a, scope/b]
      guardrails: {enabled: true, rules: [], disable: [x]}
      recap: {host: box, base-url: "http://h/v1"}
    YAML
  end

  it "says when a key can't be set in the file, and when a section isn't a mapping" do
    expect(problems("model: {profile: qwen36}\ndefault: my-model\nrecap: false\nlog:\n")).to eq([
      "config: 'model.profile' can't be set in config.yml; use SAMAGOTCHI_MODEL_PROFILE or --model-profile",
      "config: 'default' must be a mapping of settings; ignored"
    ])
  end

  it "doesn't read a flat env-named key, and suggests the nested key for it (misspelt too)" do
    expect(problems("SAMAGOTCHI_DEFAULT_MODEL: m\nSAMAGOTCHI_DEFALT_MODEL: m\nbackend: openai\n")).to eq([
      "config: unknown key 'SAMAGOTCHI_DEFAULT_MODEL' (did you mean 'default.model'?)",
      "config: unknown key 'SAMAGOTCHI_DEFALT_MODEL' (did you mean 'default.model'?)",
      "config: unknown key 'backend'"
    ])
  end

  it "no longer knows the dead bridge.enable and thinking.preview_lines" do
    expect(Samagotchi::Config.find_by_key("bridge.enable")).to be_nil
    expect(Samagotchi::Config.find_by_key("thinking.preview_lines")).to be_nil
    expect(problems("bridge: {enable: true}\nthinking: {preview_lines: 3}\n")).to eq([
      "config: unknown key 'bridge'", "config: unknown key 'thinking.preview_lines'"
    ])
  end
end
