# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require "samagotchi/bundle_manifest"

RSpec.describe Samagotchi::BundleManifest do
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
        .to raise_error(Samagotchi::BundleManifest::ValidationError, /name/)
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
        .to raise_error(Samagotchi::BundleManifest::ValidationError, /not found/)
    end

    # Every manifest problem is a ValidationError (the CLI prints it as
    # "<word> failed: …"), never a Psych error with a backtrace.
    it "raises a ValidationError for a manifest.yml that isn't valid YAML or isn't a mapping" do
      path = File.join(tmpdir, "manifest.yml")
      error = Samagotchi::BundleManifest::ValidationError

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

  describe "hooks: (class-file hooks, retired)" do
    let(:retired) { described_class::HooksRetired }

    it "refuses a manifest that lists a hook, in the retired words" do
      [{ "h.rb" => { "event" => "before_tool_call", "on_error" => "fail_closed" } },
       { "links.rb" => { "events" => %w[after_turn question_asked] } }, ["h.rb"]].each do |hooks|
        expect { described_class.new(path: write_manifest({ "hooks" => hooks })) }
          .to raise_error(retired, "hooks: #{retired::WORDS}"), hooks.inspect
      end
      expect(retired.ancestors).to include(described_class::ValidationError)
    end

    it "reads one that keeps the key empty, with no hooks and no unknown key" do
      [{}, [], nil].each do |hooks|
        m = described_class.new(path: write_manifest({ "hooks" => hooks }))
        expect(m.unknown_keys).to eq([]), hooks.inspect
      end
    end

    it "is no problem for a tolerant read (an older install's kept manifest.yml): the key is ignored" do
      manifest, problems = described_class.tolerant(path: write_manifest({ "hooks" => { "h.rb" => { "events" => "not a list" } } }))
      expect([problems, manifest.unknown_keys]).to eq([{}, []])
    end

    it "words a source's hooks/*.rb with the same words" do
      expect(retired.for_files(["hooks/a.rb", "hooks/b.rb"]).message).to eq("hooks/a.rb, hooks/b.rb: #{retired::WORDS}")
      FileUtils.mkdir_p(File.join(tmpdir, "src", "hooks"))
      %w[b.rb a.rb notes.txt].each { |file| File.write(File.join(tmpdir, "src", "hooks", file), "") }
      expect(retired.files_in(File.join(tmpdir, "src"))).to eq(["hooks/a.rb", "hooks/b.rb"])
      expect(retired.files_in(File.join(tmpdir, "none"))).to eq([])
    end

    it "defaults trust_level to experimental" do
      expect(described_class.new(path: write_manifest({})).trust_level).to eq("experimental")
    end
  end

  describe "plugin: parts:" do
    def plugin_with(parts) = { "plugin" => { "file" => "plugin.rb", "sha256" => "sha256:aa", "parts" => parts } }

    it "reads the parts in the order listed, each sha prefixed, an empty one kept" do
      manifest = described_class.new(path: write_manifest(plugin_with({ "z_client.rb" => "bb", "a_http.rb" => "sha256:cc",
                                                                        "empty.rb" => "" })))
      expect(manifest.plugin[:parts]).to eq("z_client.rb" => "sha256:bb", "a_http.rb" => "sha256:cc", "empty.rb" => "")
      expect(manifest.plugin_parts.keys).to eq(%w[z_client.rb a_http.rb empty.rb])
      expect(manifest.plugin_files).to eq([["z_client.rb", "sha256:bb"], ["a_http.rb", "sha256:cc"], ["empty.rb", ""],
                                           ["plugin.rb", "sha256:aa"]])
      expect(manifest.checksum_for_part("z_client.rb")).to eq("bb")
      expect(manifest.checksum_for_part("empty.rb")).to be_nil
      expect(manifest.checksum_for_part("nope.rb")).to be_nil
    end

    it "parses a manifest without parts to what it did before" do
      manifest = described_class.new(path: write_manifest({ "plugin" => { "file" => "plugin.rb", "sha256" => "sha256:aa" } }))
      expect(manifest.plugin).to eq(file: "plugin.rb", sha256: "sha256:aa")
      expect(manifest.plugin_parts).to eq({})
      expect(manifest.plugin_files).to eq([["plugin.rb", "sha256:aa"]])
      expect(described_class.new(path: write_manifest(plugin_with(nil))).plugin).to eq(file: "plugin.rb", sha256: "sha256:aa")
      expect(described_class.new(path: write_manifest({})).plugin_files).to eq([])
    end

    it "refuses a part that isn't a top-level .rb name, the plugin file itself, a list, or more than 16" do
      error = described_class::ValidationError
      expect { described_class.new(path: write_manifest(plugin_with({ "lib/client.rb" => "aa" }))) }
        .to raise_error(error, %(plugin parts: "lib/client.rb" isn't a .rb file name in the bundle's top directory: ) \
                               "parts sit next to plugin.rb (move lib/client.rb up and list it as client.rb)")
      nested_part = { "plugin" => { "file" => "entry.rb", "sha256" => "sha256:aa", "parts" => { "lib/oauth.rb" => "aa" } } }
      expect { described_class.new(path: write_manifest(nested_part)) }
        .to raise_error(error, %(plugin parts: "lib/oauth.rb" isn't a .rb file name in the bundle's top directory: ) \
                               "parts sit next to entry.rb (move lib/oauth.rb up and list it as oauth.rb)")
      expect { described_class.new(path: write_manifest(plugin_with({ "client.py" => "aa" }))) }
        .to raise_error(error, /"client.py" isn't a .rb file name/)
      expect { described_class.new(path: write_manifest(plugin_with({ "plugin.rb" => "aa" }))) }
        .to raise_error(error, "plugin parts: plugin.rb is the plugin file itself")
      expect { described_class.new(path: write_manifest(plugin_with(["client.rb"]))) }
        .to raise_error(error, "plugin parts: must be a mapping of file names to sha256")
      many = (1..17).to_h { |i| ["p#{i}.rb", "aa"] }
      expect { described_class.new(path: write_manifest(plugin_with(many))) }
        .to raise_error(error, "plugin parts: lists 17 files, at most 16")
      expect(described_class.new(path: write_manifest(plugin_with(many.first(16).to_h))).plugin_parts.size).to eq(16)
    end

    it "refuses a part named like the plugin file or an earlier part in another case" do
      error = described_class::ValidationError
      expect { described_class.new(path: write_manifest(plugin_with({ "a.rb" => "aa", "Plugin.rb" => "bb" }))) }
        .to raise_error(error, "plugin parts: Plugin.rb and plugin.rb differ only in case (one file on a case-insensitive disk)")
      expect { described_class.new(path: write_manifest(plugin_with({ "a.rb" => "aa", "A.rb" => "bb" }))) }
        .to raise_error(error, "plugin parts: A.rb and a.rb differ only in case (one file on a case-insensitive disk)")
    end

    it "refuses a part the YAML lists twice, which loading would collapse into one" do
      path = File.join(tmpdir, "manifest.yml")
      File.write(path, <<~YAML)
        name: b
        version: 1.0.0
        files: {}
        plugin:
          file: plugin.rb
          sha256: sha256:aa
          parts:
            a.rb: sha256:bb
            b.rb: sha256:cc
            a.rb: sha256:dd
      YAML
      expect { described_class.new(path: path) }
        .to raise_error(described_class::ValidationError, "plugin parts: a.rb is listed twice")
      expect(described_class.tolerant(path: path).last).to eq("plugin" => "plugin parts: a.rb is listed twice")
    end

    it "writes the parts back in their order, and reads them again" do
      described_class.write(dir: tmpdir, name: "b", version: "1.0.0", files: {},
                            plugin: { file: "plugin.rb", sha256: "aa", parts: { "z.rb" => "bb", "a.rb" => "sha256:cc" } })
      expect(YAML.load_file(File.join(tmpdir, "manifest.yml"))["plugin"]["parts"]).to eq("z.rb" => "sha256:bb", "a.rb" => "sha256:cc")
      expect(described_class.read(dir: tmpdir).plugin_parts.keys).to eq(%w[z.rb a.rb])
    end

    it "puts a bad parts: under the tolerant read's plugin problem" do
      manifest, problems = described_class.tolerant(path: write_manifest(plugin_with("client.rb")))
      expect(manifest.plugin).to be_nil
      expect(problems).to eq("plugin" => "plugin parts: must be a mapping of file names to sha256")
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

    it "refuses a meta with files or a plugin" do
      expect { described_class.new(path: write_manifest({ "includes" => ["a"], "files" => { "a.md" => "sha256:0" } })) }
        .to raise_error(described_class::ValidationError, "a bundle with includes: holds only its includes (no files, plugin or scripts)")
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
      # A key not released yet waits in SINCE's `# Unreleased: "key".` comment (rake release:bump gives it its version).
      source = File.read(described_class.instance_method(:initialize).source_location.first)
      unreleased = source.scan(/^\s*# Unreleased\b[^"\n]*:(.*)$/).flatten.flat_map { |names| names.scan(/"([^"]+)"/) }.flatten
      expect(described_class::KEYS - first_release - described_class::SINCE.keys - unreleased - ["requires_chi_next"]).to eq([])
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
        "hooks" => {},
        "trust_level" => "reviewed",
        "plugin" => { "file" => "plugin.rb", "sha256" => "sha256:bb" },
        "requires_chi" => ">= 0.151.0",
        "requires_chi_next" => true,
        "needs" => ["gh"],
        "scripts" => { "draw.js" => "sha256:cc" },
        "context_providers" => [{ "match" => "x", "name" => "n", "cmd" => "c" }],
        "block_renderers" => [{ "lang" => "mermaid", "load" => ["draw.js"] }],
        "pages" => [],
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

    describe "pages:" do
      it "lists page scripts, each a scripts: key named NAME.rb" do
        manifest = manifest({ "scripts" => { "schedules.rb" => "sha256:aa" }, "pages" => ["schedules.rb"] })
        expect(manifest.pages).to eq(["schedules.rb"])
        expect(manifest({}).pages).to eq([])
      end

      it "refuses a page script that isn't under scripts:, isn't NAME.rb, or comes twice" do
        scripts = { "schedules.rb" => "sha256:aa", "Bad.rb" => "sha256:bb", "draw.js" => "sha256:cc" }
        expect { manifest({ "scripts" => scripts, "pages" => ["other.rb"] }) }
          .to raise_error(described_class::ValidationError, "pages: other.rb isn't under scripts:")
        expect { manifest({ "scripts" => scripts, "pages" => ["Bad.rb"] }) }
          .to raise_error(described_class::ValidationError, /pages: "Bad.rb" isn't a page script \(NAME.rb/)
        expect { manifest({ "scripts" => scripts, "pages" => ["draw.js"] }) }
          .to raise_error(described_class::ValidationError, /pages: "draw.js" isn't a page script/)
        expect { manifest({ "scripts" => scripts, "pages" => "schedules.rb" }) }
          .to raise_error(described_class::ValidationError, /pages: must be a list/)
        expect { manifest({ "scripts" => scripts, "pages" => ["schedules.rb", "schedules.rb"] }) }
          .to raise_error(described_class::ValidationError, "pages: schedules.rb listed more than once")
      end

      it "writes the list back" do
        Dir.mktmpdir do |dir|
          described_class.write(dir: dir, name: "b", version: "1.0.0", files: {}, scripts: { "schedules.rb" => "sha256:aa" },
                                pages: ["schedules.rb"])
          expect(described_class.read(dir: dir).pages).to eq(["schedules.rb"])
        end
      end
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
        # A profile's includes: is on its own: a meta ships no files, plugin or scripts.
        expect(manifest("includes" => ["core"]).floor_keys).to eq("includes" => "0.8.0")
      end

      it "counts the shapes only a newer chi reads: a files: mapping, a typed session_settings: or settings:" do
        manifest = manifest({
          "files" => { "identity.md" => { "sha256" => "sha256:aa", "description" => "Use when x" } },
          "session_settings" => { "cap" => "number" },
          "settings" => { "greeting" => "string" }
        })
        expect(manifest.floor_keys).to eq("files.description" => "0.34.0",
                                          "session_settings" => "0.84.0", "session_settings.types" => "0.92.0",
                                          "settings" => "0.143.0", "settings.types" => "0.92.0")
      end

      it "counts plugin: parts: once its release is in SINCE" do
        stub_const("#{described_class}::SINCE", described_class::SINCE.merge("plugin.parts" => "9.9.9"))
        manifest = manifest({ "plugin" => { "file" => "plugin.rb", "sha256" => "", "parts" => { "a.rb" => "" } } })
        expect(manifest.floor_keys).to eq("plugin.parts" => "9.9.9")
      end

      it "takes no floor from a plain files: entry" do
        manifest = manifest({ "files" => { "a.md" => "sha256:aa" } })
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
