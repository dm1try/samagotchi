# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require "samagotchi/memory_bundle/manifest"

RSpec.describe Samagotchi::MemoryBundle::Manifest do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-manifest-") }

  after { FileUtils.rm_rf(tmpdir) }

  def write_manifest(attrs)
    attrs = attrs.dup.transform_keys(&:to_s)
    attrs["name"] ||= "test-bundle"
    attrs["version"] ||= "1.0.0"
    attrs["files"] ||= {}
    manifest_path = File.join(tmpdir, "manifest.yml")
    File.write(manifest_path, YAML.dump(attrs))
    manifest_path
  end

  describe "#initialize" do
    it "parses a valid manifest" do
      path = write_manifest({
        "name" => "my-bundle",
        "version" => "2.1.0",
        "scope" => "system",
        "description" => "A test bundle",
        "files" => {
          "identity.md" => "sha256:abc123",
          "commit_preferences.md" => "def456"
        }
      })
      manifest = described_class.new(path: path)
      expect(manifest.name).to eq("my-bundle")
      expect(manifest.version).to eq("2.1.0")
      expect(manifest.scope).to eq("system")
      expect(manifest.description).to eq("A test bundle")
      expect(manifest.checksum_for("identity.md")).to eq("abc123")
      expect(manifest.checksum_for("commit_preferences.md")).to eq("def456")
    end

    it "refuses a name that is a path (it names a directory under .bundles/), keeps a dotted one" do
      ["../x", "a/b", "a\\b", ".", ".."].each do |name|
        path = write_manifest("name" => name)
        expect { described_class.new(path: path) }
          .to raise_error(described_class::ValidationError, /is not a bundle name/), "name #{name.inspect}"
      end
      expect(described_class.new(path: write_manifest("name" => "my.bundle")).name).to eq("my.bundle")
    end

    it "reads a files: entry given as a mapping: its sha in files, its description apart" do
      path = write_manifest({
        "files" => {
          "identity.md" => "sha256:abc123",
          "skill_x.md" => { "sha256" => "sha256:def456", "description" => " Use when x " },
          "plain.md" => { "sha256" => "789" }
        }
      })
      manifest = described_class.new(path: path)
      expect(manifest.files).to eq("identity.md" => "sha256:abc123", "skill_x.md" => "sha256:def456", "plain.md" => "sha256:789")
      expect(manifest.checksum_for("skill_x.md")).to eq("def456")
      expect(manifest.file_descriptions).to eq("skill_x.md" => "Use when x")
    end

    it "writes files with a description as mappings and the rest as plain sha lines" do
      described_class.write(dir: tmpdir, name: "b", version: "1.0.0",
                            files: { "a.md" => "sha256:aa", "skill_x.md" => "sha256:bb" },
                            file_descriptions: { "skill_x.md" => "Use when x" })

      raw = YAML.load_file(File.join(tmpdir, "manifest.yml"))
      expect(raw["files"]).to eq("a.md" => "sha256:aa", "skill_x.md" => { "sha256" => "sha256:bb", "description" => "Use when x" })
      expect(described_class.read(dir: tmpdir).file_descriptions).to eq("skill_x.md" => "Use when x")
    end

    it "strips sha256: prefix from checksum_for when present" do
      path = write_manifest({
        "files" => { "foo.md" => "sha256:abcdef012345" }
      })
      manifest = described_class.new(path: path)
      expect(manifest.checksum_for("foo.md")).to eq("abcdef012345")
    end

    it "returns bare hex when no prefix" do
      path = write_manifest({
        "files" => { "foo.md" => "abcdef012345" }
      })
      manifest = described_class.new(path: path)
      expect(manifest.checksum_for("foo.md")).to eq("abcdef012345")
    end

    it "returns nil for unknown file key" do
      path = write_manifest({ "files" => { "foo.md" => "sha256:abc" } })
      manifest = described_class.new(path: path)
      expect(manifest.checksum_for("bar.md")).to be_nil
    end

    it "returns nil for a files entry that declares no checksum" do
      path = write_manifest({ "files" => { "foo.md" => { "description" => "Just a description" } } })
      manifest = described_class.new(path: path)
      expect(manifest.checksum_for("foo.md")).to be_nil
    end

    it "defaults scope to nil when not provided" do
      path = write_manifest({})
      manifest = described_class.new(path: path)
      expect(manifest.scope).to be_nil
    end

    it "rejects invalid scope values" do
      path = write_manifest({ "scope" => "invalid" })
      manifest = described_class.new(path: path)
      expect(manifest.scope).to be_nil
    end

    it "raises on missing required fields" do
      File.write(File.join(tmpdir, "manifest.yml"), YAML.dump({}))
      expect { described_class.new(path: File.join(tmpdir, "manifest.yml")) }
        .to raise_error(Samagotchi::MemoryBundle::Manifest::ValidationError, /name/)
    end

    it "ignores empty file keys" do
      path = write_manifest({ "files" => { "" => "sha256:abc", "valid.md" => "sha256:def" } })
      manifest = described_class.new(path: path)
      expect(manifest.files).to eq({ "valid.md" => "sha256:def" })
    end
  end

  describe ".read" do
    it "reads from a directory" do
      write_manifest({})
      manifest = described_class.read(dir: tmpdir)
      expect(manifest.name).to eq("test-bundle")
    end

    it "raises when no manifest.yml in dir" do
      expect { described_class.read(dir: tmpdir) }
        .to raise_error(Samagotchi::MemoryBundle::Manifest::ValidationError, /not found/)
    end

    # Every manifest problem is a ValidationError (the CLI prints it as
    # "<word> failed: …"), never a Psych error with a backtrace.
    it "raises a ValidationError for a manifest.yml that isn't valid YAML or isn't a mapping" do
      path = File.join(tmpdir, "manifest.yml")
      error = Samagotchi::MemoryBundle::Manifest::ValidationError

      File.write(path, "name: [x\n")
      expect { described_class.read(dir: tmpdir) }
        .to raise_error(error, "manifest.yml is not valid YAML in #{tmpdir}: line 1, column 7: did not find expected ',' or ']'")
      File.write(path, "name: &n x\nversion: *n\n")
      expect { described_class.read(dir: tmpdir) }
        .to raise_error(error, /\Amanifest\.yml is not valid YAML in #{Regexp.escape(tmpdir)}: Alias parsing was not enabled/)
      File.write(path, "- name\n- version\n")
      expect { described_class.read(dir: tmpdir) }.to raise_error(error, "manifest.yml is not a YAML mapping in #{tmpdir}")
      File.write(path, "")
      expect { described_class.read(dir: tmpdir) }.to raise_error(error, "manifest missing required field: name")
    end
  end

  describe ".write" do
    it "writes a valid manifest.yml" do
      dest = File.join(tmpdir, "output")
      described_class.write(
        dir: dest,
        name: "new-bundle",
        version: "1.0.0",
        scope: "project",
        description: "Created by test",
        files: { "test.md" => "sha256:xyz789" }
      )
      manifest = described_class.read(dir: dest)
      expect(manifest.name).to eq("new-bundle")
      expect(manifest.version).to eq("1.0.0")
      expect(manifest.scope).to eq("project")
      expect(manifest.description).to eq("Created by test")
      expect(manifest.checksum_for("test.md")).to eq("xyz789")
    end

    it "omits scope from yaml when nil" do
      dest = File.join(tmpdir, "output2")
      described_class.write(dir: dest, name: "n", version: "1", scope: nil, files: {})
      content = File.read(File.join(dest, "manifest.yml"))
      expect(content).not_to include("scope:")
    end
  end

  describe "hooks" do
    it "parses hooks: sha/event/on_error/priority with defaults and both hex forms" do
      path = write_manifest({
        "hooks" => {
          "guardrails.rb" => { "sha256" => "abc123", "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => "10" },
          "audit.rb" => { "sha256" => "sha256:def456", "event" => "after_tool_call" }
        },
        "trust_level" => "reviewed"
      })
      m = described_class.new(path: path)
      expect(m.hooks["guardrails.rb"].sha256).to eq("sha256:abc123")
      expect(m.hooks["guardrails.rb"].events).to eq(["before_tool_call"])
      expect(m.hooks["guardrails.rb"].on_error).to eq("fail_closed")
      expect(m.hooks["guardrails.rb"].priority).to eq(10)
      expect(m.hooks["audit.rb"].on_error).to eq("skip") # default
      expect(m.hooks["audit.rb"].priority).to eq(100)
      expect(m.trust_level).to eq("reviewed")
    end

    it "parses events: a list, one hook for each event it names" do
      path = write_manifest({ "hooks" => { "links.rb" => { "events" => %w[after_turn question_asked], "on_error" => "log" } } })
      expect(described_class.new(path: path).hooks["links.rb"].events).to eq(%w[after_turn question_asked])
    end

    it "refuses an events: that isn't a list of event names, or one given with event:" do
      error = described_class::ValidationError
      { "after_turn" => "hooks: h.rb: events: must be a list of event names",
        [] => "hooks: h.rb: events: must be a list of event names",
        ["after_turn", 3] => "hooks: h.rb: events: 3 is not an event name",
        ["After Turn"] => 'hooks: h.rb: events: "After Turn" is not an event name' }.each do |events, message|
        path = write_manifest({ "hooks" => { "h.rb" => { "events" => events } } })
        expect { described_class.new(path: path) }.to raise_error(error, message), events.inspect
      end
      path = write_manifest({ "hooks" => { "h.rb" => { "event" => "after_turn", "events" => ["question_asked"] } } })
      expect { described_class.new(path: path) }.to raise_error(error, "hooks: h.rb: give event: or events:, not both")
    end

    it "write round-trips an events: list" do
      dest = File.join(tmpdir, "out_events")
      described_class.write(dir: dest, name: "ev", version: "1.0.0", scope: "system", description: "", files: {},
                            hooks: { "links.rb" => { "events" => %w[after_turn question_asked] } })
      expect(described_class.read(dir: dest).hooks["links.rb"].events).to eq(%w[after_turn question_asked])
    end

    it "defaults trust_level to experimental" do
      path = write_manifest({})
      m = described_class.new(path: path)
      expect(m.trust_level).to eq("experimental")
      expect(m.hooks).to eq({})
    end

    it "ignores non-string hook keys and empty basenames" do
      path = write_manifest({ "hooks" => { "" => { "sha256" => "abc", "event" => "x" }, 123 => { "sha256" => "abc" } } })
      m = described_class.new(path: path)
      expect(m.hooks).to be_empty
    end

    it "checksum_for_hook strips prefix and handles both forms" do
      path = write_manifest({ "hooks" => { "a.rb" => { "sha256" => "sha256:xyz", "event" => "e" }, "b.rb" => { "sha256" => "bare", "event" => "e" } } })
      m = described_class.new(path: path)
      expect(m.checksum_for_hook("a.rb")).to eq("xyz")
      expect(m.checksum_for_hook("b.rb")).to eq("bare")
      expect(m.checksum_for_hook("missing.rb")).to be_nil
    end

    it "write round-trips hooks and trust_level" do
      dest = File.join(tmpdir, "out_hooks")
      described_class.write(
        dir: dest,
        name: "hook-bundle",
        version: "1.0.0",
        scope: "system",
        description: "with hooks",
        files: {},
        hooks: { "guardrails.rb" => { "sha256" => "sha256:abc", "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => 10 } },
        trust_level: "reviewed"
      )
      m = described_class.read(dir: dest)
      expect(m.hooks["guardrails.rb"].events).to eq(["before_tool_call"])
      expect(m.trust_level).to eq("reviewed")
      expect(m.checksum_for_hook("guardrails.rb")).to eq("abc")
    end
  end

  describe "needs" do
    it "is empty when the manifest has none" do
      expect(described_class.new(path: write_manifest({})).needs).to eq([])
    end

    it "parses the long form and the short form" do
      path = write_manifest({ "needs" => [{ "command" => "gh", "why" => "reads PRs", "hint" => "brew install gh" }, "jq"] })
      expect(described_class.new(path: path).needs).to eq([
        { command: "gh", why: "reads PRs", hint: "brew install gh" },
        { command: "jq", why: nil, hint: nil }
      ])
    end

    it "merges duplicate commands, the first one's why and hint winning" do
      path = write_manifest({ "needs" => [{ "command" => "gh", "why" => "first" }, { "command" => "gh", "why" => "second" }] })
      expect(described_class.new(path: path).needs).to eq([{ command: "gh", why: "first", hint: nil }])
    end

    it "rejects a command that is a path or has spaces" do
      ["/usr/bin/gh", "gh auth", "", "-x"].each do |bad|
        path = write_manifest({ "needs" => [bad] })
        expect { described_class.new(path: path) }.to raise_error(described_class::ValidationError, /plain command name/)
      end
    end

    it "rejects needs that isn't a list, or an item that isn't a name or mapping" do
      expect { described_class.new(path: write_manifest({ "needs" => "gh" })) }
        .to raise_error(described_class::ValidationError, /must be a list/)
      expect { described_class.new(path: write_manifest({ "needs" => [42] })) }
        .to raise_error(described_class::ValidationError, /each item/)
    end

    it "round-trips through write in the long form, dropping empty why/hint" do
      dest = File.join(tmpdir, "out")
      described_class.write(dir: dest, name: "n", version: "1", files: {},
                            needs: [{ command: "gh", why: "reads PRs", hint: nil }, { command: "jq" }])
      expect(YAML.load_file(File.join(dest, "manifest.yml"))["needs"])
        .to eq([{ "command" => "gh", "why" => "reads PRs" }, { "command" => "jq" }])
      expect(described_class.read(dir: dest).needs).to eq([
        { command: "gh", why: "reads PRs", hint: nil },
        { command: "jq", why: nil, hint: nil }
      ])
    end

    it "writes no needs key when there are none" do
      dest = File.join(tmpdir, "out")
      described_class.write(dir: dest, name: "n", version: "1", files: {}, needs: [])
      expect(YAML.load_file(File.join(dest, "manifest.yml"))).not_to have_key("needs")
    end
  end

  describe "includes" do
    it "is empty when absent" do
      expect(described_class.new(path: write_manifest({})).includes).to eq([])
    end

    it "reads a list of bundle names; the manifest is then a meta" do
      m = described_class.new(path: write_manifest({ "files" => nil, "includes" => %w[loop-guard check-in loop-guard] }))
      expect(m.includes).to eq(%w[loop-guard check-in])
      expect(m.meta?).to be(true)
    end

    it "refuses includes that isn't a list of plain names" do
      expect { described_class.new(path: write_manifest({ "includes" => "loop-guard" })) }
        .to raise_error(described_class::ValidationError, /includes: must be a list/)
      expect { described_class.new(path: write_manifest({ "includes" => ["../x"] })) }
        .to raise_error(described_class::ValidationError, /not a bundle name/)
    end

    it "refuses a meta with files, hooks or a plugin" do
      expect { described_class.new(path: write_manifest({ "includes" => ["a"], "files" => { "a.md" => "sha256:0" } })) }
        .to raise_error(described_class::ValidationError, /holds only its includes/)
      expect { described_class.new(path: write_manifest({ "includes" => ["a"], "hooks" => { "h.rb" => { "event" => "after_turn" } } })) }
        .to raise_error(described_class::ValidationError, /holds only its includes/)
      expect { described_class.new(path: write_manifest({ "includes" => ["a"], "plugin" => { "file" => "p.rb" } })) }
        .to raise_error(described_class::ValidationError, /holds only its includes/)
    end
  end

  describe "the keys this chi reads, and the release each one came in" do
    # Manifest#initialize's own body, from its def to the line that ends it:
    # every raw["…"] there is a key chi reads. parse_plugin's raw["file"] and
    # raw["sha256"] sit past that end, so they aren't caught here.
    def initialize_body
      file, line = described_class.instance_method(:initialize).source_location
      lines = File.readlines(file)
      indent = lines[line - 1][/\A */].size
      # The method's own end, at the def's indentation, closes it: an inner
      # if's end is deeper.
      lines[(line - 1)..].take_while { |text| text.strip != "end" || text[/\A */].size != indent }
    end

    def manifest(attrs) = described_class.new(path: write_manifest(attrs))

    it "lists every key its parser reads and nothing else" do
      read = initialize_body.flat_map { |line| line.scan(/\braw\[["']([a-z_]+)["']\]/) }.flatten.uniq
      expect(read - described_class::KEYS).to eq([])
      # name and version arrive through require_str; requires_chi_next is the
      # release tooling's marker (docs/releasing.md), read nowhere in Manifest.
      expect(described_class::KEYS - read).to eq(%w[name version requires_chi_next])
    end

    it "has a floor for every key newer than the first release (v0.2.0, read from git)" do
      first_release = %w[name version scope description files hooks trust_level plugin requires_chi needs]
      expect(described_class::KEYS - first_release - described_class::SINCE.keys - ["requires_chi_next"]).to eq([])
      expect(described_class::SINCE.keys.reject { |key| described_class::KEYS.include?(key.split(".").first) }).to eq([])
    end

    it "reports a key this chi doesn't read, in the order the manifest lists them" do
      path = File.join(tmpdir, "manifest.yml")
      File.write(path, <<~YAML)
        name: future-bundle
        version: 1.0.0
        card_layouts: [cards, panels]
        files:
          identity.md: sha256:aa
        api_version: 3
      YAML
      expect(described_class.new(path: path).unknown_keys).to eq(%w[card_layouts api_version])
    end

    it "has no unknown key for a manifest that uses every key chi knows" do
      manifest = manifest({
        "scope" => "system",
        "description" => "all of them",
        "files" => { "identity.md" => "sha256:aa" },
        "hooks" => { "h.rb" => { "event" => "after_turn" } },
        "trust_level" => "reviewed",
        "plugin" => { "file" => "plugin.rb", "sha256" => "sha256:bb" },
        "requires_chi" => ">= 0.151.0",
        "requires_chi_next" => true,
        "needs" => ["gh"],
        "scripts" => { "draw.js" => "sha256:cc" },
        "context_providers" => [{ "match" => "x", "name" => "n", "cmd" => "c" }],
        "block_renderers" => [{ "lang" => "mermaid", "load" => ["draw.js"] }],
        "session_settings" => ["cap"],
        "settings" => ["greeting"]
      })
      expect(manifest.unknown_keys).to eq([])
      expect(manifest.name).to eq("test-bundle")
    end

    it "words the unknown key once, for every caller to add its own fix to" do
      expect(described_class.unknown_key_line("card_layouts")).to eq(
        "this chi (#{Samagotchi::VERSION}) doesn't know the manifest key card_layouts:, so it ignores it"
      )
    end

    describe "#floor_keys" do
      it "is empty for a manifest of only the first release's keys" do
        expect(manifest({}).floor_keys).to eq({})
      end

      it "names each key it uses with the release that first read it" do
        manifest = manifest({
          "scripts" => { "draw.js" => "sha256:aa" },
          "context_providers" => [{ "match" => "x", "name" => "n", "cmd" => "c" }],
          "block_renderers" => [{ "lang" => "mermaid", "load" => ["draw.js"] }],
          "session_settings" => ["cap"],
          "settings" => ["greeting"]
        })
        expect(manifest.floor_keys).to eq("scripts" => "0.32.0", "context_providers" => "0.32.0",
                                          "block_renderers" => "0.151.0", "session_settings" => "0.84.0", "settings" => "0.143.0")
        # A profile's includes: is on its own: a meta ships no files, hooks, plugin or scripts.
        expect(manifest("includes" => ["core"]).floor_keys).to eq("includes" => "0.8.0")
      end

      it "counts the shapes only a newer chi reads: a files: mapping, a hook's events:, a typed session_settings: or settings:" do
        manifest = manifest({
          "files" => { "identity.md" => { "sha256" => "sha256:aa", "description" => "Use when x" } },
          "hooks" => { "h.rb" => { "events" => ["after_turn"] } },
          "session_settings" => { "cap" => "number" },
          "settings" => { "greeting" => "string" }
        })
        expect(manifest.floor_keys).to eq("files.description" => "0.34.0", "hooks.events" => "0.98.0",
                                          "session_settings" => "0.84.0", "session_settings.types" => "0.92.0",
                                          "settings" => "0.143.0", "settings.types" => "0.92.0")
      end

      it "takes no floor from a plain files: entry or a hook with only event:" do
        manifest = manifest({ "files" => { "a.md" => "sha256:aa" }, "hooks" => { "h.rb" => { "event" => "after_turn" } } })
        expect(manifest.floor_keys).to eq({})
      end

      it "is empty keys when an unknown one is next to a known one" do
        manifest = manifest("includes" => ["core"], "card_layouts" => ["cards"])
        expect(manifest.unknown_keys).to eq(["card_layouts"])
        expect(manifest.floor_keys).to eq("includes" => "0.8.0")
      end
    end
  end
end
