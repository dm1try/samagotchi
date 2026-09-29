# frozen_string_literal: true

require "yaml"
require "samagotchi/config"

# docs/configuration.md is where people copy config.yml from, so every ```yaml
# block in it must be a config the loader takes without a warning: only keys
# the code reads (a flat SAMAGOTCHI_* key isn't one).
RSpec.describe "docs/configuration.md YAML examples" do
  doc_path = File.expand_path("../docs/configuration.md", __dir__)

  # [line, yaml] for every ```yaml fence, dedented (a fence may sit in a list item).
  blocks = lambda do |text|
    text.to_enum(:scan, /^( *)```yaml\n(.*?)^\1```/m).map do
      match = Regexp.last_match
      [text[0...match.begin(0)].count("\n") + 1, match[2].gsub(/^#{match[1]}/, "")]
    end
  end

  # The loader's own check (unknown keys, map entry keys).
  problems_in = lambda do |data|
    next ["top level is not a mapping"] unless data.is_a?(Hash)

    Samagotchi::Config.validate_yaml_sections(data)
  end

  it "has YAML examples to check" do
    expect(blocks.call(File.read(doc_path)).size).to be >= 5
  end

  it "uses only nested keys the config reads" do
    problems = blocks.call(File.read(doc_path)).flat_map do |line, yaml|
      data = YAML.safe_load(yaml, permitted_classes: [], aliases: false)
      problems_in.call(data).map { |p| "line #{line}: #{p}" }
    rescue Psych::Exception => e
      ["line #{line}: does not parse: #{e.message}"]
    end
    expect(problems).to eq([])
  end

  it "flags a flat env-named key, an unknown key and an unknown host key" do
    data = YAML.safe_load(<<~YAML)
      SAMAGOTCHI_DEFAULT_MODEL: m
      server: {port: 1, colour: red}
      hosts: {a: {host: h, colour: red}}
      recap: {host: a}
    YAML
    expect(problems_in.call(data)).to contain_exactly(
      "config: unknown key 'SAMAGOTCHI_DEFAULT_MODEL' (did you mean 'default.model'?)",
      "config: unknown key 'server.colour'", "config: unknown key 'hosts.a.colour'"
    )
  end
end
