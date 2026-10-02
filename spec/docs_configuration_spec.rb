# frozen_string_literal: true

require "yaml"
require "samagotchi/config"

# docs/configuration.md is where people copy config.yml from, so every ```yaml
# block in it must be a config the loader takes without a warning: only keys
# the code reads (a flat SAMAGOTCHI_* key isn't one). Its "All settings" table
# follows Config::ENTRIES: every key, the CLI column, the literal defaults.
RSpec.describe "docs/configuration.md YAML examples and settings table" do
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

  # The "All settings" table: | `key` | default | CLI | what it does |.
  settings_rows = lambda do
    table = File.read(doc_path).split(/^## All settings$/, 2).last[/(?:^\|.*\n)+/]
    table.lines.drop(2).filter_map do |line|
      key, default, cli = line.strip.delete_prefix("|").delete_suffix("|").split(/(?<!\\)\|/).map(&:strip)
      key = key[/\A`([a-z_.]+)`\z/, 1]
      [key, default.gsub("\\|", "|"), cli] if key
    end
  end
  entries = Samagotchi::Config::ENTRIES.to_h { |entry| [entry.key, entry] }
  # Settings whose flag is hand-written in bin/chi, not generated.
  own_flags = { "thinking.level" => "`--thinking`" }

  it "lists every config.yml setting, and only those, in the settings table" do
    documented = settings_rows.call.map(&:first)
    in_config = entries.values.select { |entry| entry.expose.include?(:config) }.map(&:key)
    expect(documented - entries.keys).to eq([])
    expect(in_config - documented).to eq([])
  end

  it "gives the settings table's CLI column and literal defaults as the registry has them" do
    problems = settings_rows.call.flat_map do |key, default, cli|
      entry = entries.fetch(key)
      cli_ok = if own_flags.key?(key) then cli == own_flags[key]
               elsif entry.expose.include?(:cli) then !cli.empty?
               else cli.empty?
               end
      found = []
      found << "#{key}: CLI column #{cli.inspect}" unless cli_ok
      literal = default[/\A`([^`]*)`\z/, 1]
      if literal && !entry.default.nil?
        same = entry.default.is_a?(Numeric) ? Float(literal, exception: false) == entry.default : literal == entry.default.to_s
        found << "#{key}: default #{literal} in the doc, #{entry.default.inspect} in the code" unless same
      end
      found
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
