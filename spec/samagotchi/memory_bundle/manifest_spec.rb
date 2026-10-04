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
      expect(m.hooks["guardrails.rb"][:sha256]).to eq("sha256:abc123")
      expect(m.hooks["guardrails.rb"][:event]).to eq("before_tool_call")
      expect(m.hooks["guardrails.rb"][:on_error]).to eq("fail_closed")
      expect(m.hooks["guardrails.rb"][:priority]).to eq(10)
      expect(m.hooks["audit.rb"][:on_error]).to eq("skip") # default
      expect(m.hooks["audit.rb"][:priority]).to eq(100)
      expect(m.trust_level).to eq("reviewed")
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
      expect(m.hooks["guardrails.rb"][:event]).to eq("before_tool_call")
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
end
