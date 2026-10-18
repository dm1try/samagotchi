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

  it "assigns a valid lifecycle to every config-exposed entry" do
    missing = entries.values.select(&:config_exposed?).reject do |entry|
      Samagotchi::Config::LIFECYCLES.include?(entry.lifecycle)
    end
    expect(missing.map(&:key)).to eq([])
  end

  lifecycle_applies = {
    new_session: "New session",
    session_creation: "Session creation",
    next_cli_run: "Next CLI run",
    next_matching_use: "Next matching request or tool use",
    worker_start: "Worker start",
    next_broadcast: "Next `chi broadcast`",
    next_retention_sweep: "Next retention sweep",
    next_invocation: "Next `chi` invocation",
    next_lifecycle_decision: "Worker start or next matching lifecycle decision",
    next_tool_or_approval: "Next tool call or approval",
    process_start: "Process start",
    next_context_poll: "Next context poll",
    prompt_rebuild: "Prompt rebuild",
    next_turn_start: "Next turn start",
    next_request_or_turn_end: "Next request or turn-end warm-up",
    next_update: "Next `chi update`",
    desktop_update: "`chi desktop upgrade` or desktop update",
    web_start: "`chi web` start",
    next_empty_answer_retry: "Next empty-answer retry",
    next_history_access: "Next history access",
    next_matching_turn_display_poll_write: "Next matching turn, display, poll or write"
  }.freeze
  applies_rows = lambda do
    text = File.read(doc_path).split(/^## When a change applies$/, 2).last
    table = text.split(/^### Environment variables$/, 2).first
    table.lines.filter_map do |line|
      key_cell, applies = line.strip.delete_prefix("|").split("|", 3).first(2).map(&:strip)
      next unless applies

      excluded = key_cell.scan(/except\s+`([^`]+)`/).flatten
      keys = key_cell.scan(/`([^`]+)`/).flatten - excluded
      [keys, excluded, applies]
    end
  end
  row_matches = lambda do |key|
    applies_rows.call.select do |keys, excluded, _applies|
      !excluded.include?(key) && keys.any? do |candidate|
        candidate.include?("*") ? File.fnmatch?(candidate, key) : candidate == key
      end
    end
  end

  it "covers each config setting once with the lifecycle's Applies wording" do
    config_entries = entries.values.select(&:config_exposed?)
    problems = config_entries.flat_map do |entry|
      applies = lifecycle_applies[entry.lifecycle]
      unless applies && Samagotchi::Config::LIFECYCLES.include?(entry.lifecycle)
        next ["#{entry.key}: invalid lifecycle #{entry.lifecycle.inspect}"]
      end

      rows = row_matches.call(entry.key)
      if rows.size != 1
        ["#{entry.key}: covered by #{rows.size} lifecycle rows, expected one"]
      elsif !rows.first.last.start_with?(applies)
        ["#{entry.key}: lifecycle #{entry.lifecycle} expects Applies #{applies.inspect}, got #{rows.first.last.inspect}"]
      else
        []
      end
    end
    expect(problems).to eq([])
  end

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
        # Exact on purpose: the doc's literal must be the default as written.
        same = entry.default.is_a?(Numeric) ? Float(literal, exception: false) == entry.default : literal == entry.default.to_s # rubocop:disable Lint/FloatComparison
        found << "#{key}: default #{literal} in the doc, #{entry.default.inspect} in the code" unless same
      end
      found
    end
    expect(problems).to eq([])
  end

  # The table says every setting has an environment variable; the few
  # without one (a parent's environment must not change them) say so.
  it "marks a config.yml-only setting (no environment variable) in its row" do
    table = File.read(doc_path).split(/^## All settings$/, 2).last[/(?:^\|.*\n)+/]
    config_only = entries.values.select { |entry| entry.config_exposed? && !entry.env_exposed? }.map(&:key)
    expect(config_only).not_to be_empty
    unmarked = config_only.reject do |key|
      table.lines.find { |line| line.start_with?("| `#{key}` |") }.to_s.include?("config.yml only")
    end
    expect(unmarked).to eq([])
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
