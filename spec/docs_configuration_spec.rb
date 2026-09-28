# frozen_string_literal: true

require "yaml"
require "samagotchi/config"

# docs/configuration.md is where people copy config.yml from, so every ```yaml
# block in it must be a config the loader takes without a warning: nested
# keys only (no legacy flat SAMAGOTCHI_* keys), and only keys the code reads.
RSpec.describe "docs/configuration.md YAML examples" do
  doc_path = File.expand_path("../docs/configuration.md", __dir__)

  # The maps Config's registry leaves to their own readers, with the keys
  # each entry may hold (nil: entry names and contents are free-form).
  # ConfigFile.hosts_config / model_settings / Engine#guardrail_rules.
  map_entry_keys = {
    "hosts" => %w[host port url transport api api_key_env profile first_token_timeout vision enabled],
    "models" => %w[profile vision],
    "model_aliases" => nil,
    "hooks" => nil,
    "bundles" => nil,
    "memories" => nil
  }
  section_keys = { "guardrails" => %w[rules disable] }

  # Registry leaves the file may set, by section; "" holds top-level leaves.
  registry = Samagotchi::Config.all_entries.select(&:config_exposed?).each_with_object(Hash.new { |h, k| h[k] = [] }) do |entry, acc|
    *section, leaf = entry.yaml_path
    acc[section.join(".")].push(leaf, leaf.tr("_", "-"), *Array(entry.yaml_aliases))
  end

  # [line, yaml] for every ```yaml fence, dedented (a fence may sit in a list item).
  blocks = lambda do |text|
    text.to_enum(:scan, /^( *)```yaml\n(.*?)^\1```/m).map do
      match = Regexp.last_match
      [text[0...match.begin(0)].count("\n") + 1, match[2].gsub(/^#{match[1]}/, "")]
    end
  end

  problems_in = lambda do |data|
    problems = []
    unless data.is_a?(Hash)
      next ["top level is not a mapping"]
    end

    data.each do |key, value|
      key = key.to_s
      if key.start_with?("SAMAGOTCHI_")
        problems << "legacy flat key #{key}"
      elsif map_entry_keys.key?(key)
        allowed = map_entry_keys[key]
        next if allowed.nil? || !value.is_a?(Hash)

        value.each do |name, entry|
          next unless entry.is_a?(Hash)

          (entry.keys.map(&:to_s) - allowed).each { |k| problems << "unknown key #{key}.#{name}.#{k}" }
        end
      elsif registry.key?(key) || section_keys.key?(key)
        # An all-commented section is nil; recap: false turns recaps off.
        next if value.nil? || (key == "recap" && value == false)
        next problems << "#{key} is not a mapping" unless value.is_a?(Hash)

        allowed = registry.fetch(key, []) + section_keys.fetch(key, [])
        (value.keys.map(&:to_s) - allowed).each { |k| problems << "unknown key #{key}.#{k}" }
      elsif !registry[""].include?(key)
        problems << "unknown top-level key #{key}"
      end
    end
    problems + Samagotchi::Config.validate_yaml_sections(data)
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

  it "flags a legacy flat key, an unknown key and an unknown host key" do
    data = YAML.safe_load(<<~YAML)
      SAMAGOTCHI_DEFAULT_MODEL: m
      server: {port: 1, colour: red}
      hosts: {a: {host: h, colour: red}}
      recap: {host: a}
    YAML
    expect(problems_in.call(data)).to contain_exactly(
      "legacy flat key SAMAGOTCHI_DEFAULT_MODEL", "unknown key server.colour", "unknown key hosts.a.colour"
    )
  end
end
