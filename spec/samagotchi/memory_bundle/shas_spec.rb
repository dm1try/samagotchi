# frozen_string_literal: true

require "spec_helper"
require "digest"
require "fileutils"
require "tmpdir"
require "yaml"
require "samagotchi/memory_bundle/shas"

# The sha256 lines of a bundle manifest: `rake bundles:sha`, `chi bundle check --fix`.
RSpec.describe Samagotchi::MemoryBundle::Shas do
  let(:tmp) { Dir.mktmpdir("shas-") }

  after { FileUtils.rm_rf(tmp) }

  def sha(text) = Digest::SHA256.hexdigest(text)

  def write(rel, text)
    path = File.join(tmp, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  describe ".refresh" do
    let(:dir) { File.join(tmp, "b") }
    let(:manifest) do
      <<~YAML
        ---
        name: b
        version: 0.1.0
        files:
          a.md: sha256:#{sha("old")}
          "q.md": sha256:#{sha("q")}
        hooks:
          h.rb:
            sha256: sha256:#{sha("old")}
            event: before_tool_call
        plugin:
          file: plugin.rb
          sha256: sha256:#{sha("p")}
        requires_chi: ">= 0.1.30"
      YAML
    end

    before do
      write("b/a.md", "new a")
      write("b/q.md", "q")
      write("b/hooks/h.rb", "new h")
      write("b/plugin.rb", "p")
    end

    it "recomputes the stale sha lines and keeps everything else byte for byte" do
      text, changes = described_class.refresh(dir, manifest)
      expect(changes).to eq([["a.md", sha("old"), sha("new a")], ["hooks/h.rb", sha("old"), sha("new h")]])
      expect(text).to eq(manifest.sub("a.md: sha256:#{sha("old")}", "a.md: sha256:#{sha("new a")}")
                                 .sub("sha256: sha256:#{sha("old")}", "sha256: sha256:#{sha("new h")}"))
    end

    it "refreshes a scripts: line from scripts/<file>" do
      write("b/scripts/pr.rb", "new s")
      text = "---\nname: b\nscripts:\n  pr.rb: sha256:#{sha("old")}\ncontext_providers:\n- match: x\n"

      refreshed, changes = described_class.refresh(dir, text)

      expect(changes).to eq([["scripts/pr.rb", sha("old"), sha("new s")]])
      expect(refreshed).to eq(text.sub(sha("old"), sha("new s")))
    end

    it "refreshes a files: entry given as a mapping with a description" do
      text = <<~YAML
        ---
        name: b
        files:
          a.md:
            sha256: sha256:#{sha("old")}
            description: "Use when x"
          q.md: sha256:#{sha("q")}
      YAML

      refreshed, changes = described_class.refresh(dir, text)

      expect(changes).to eq([["a.md", sha("old"), sha("new a")]])
      expect(refreshed).to eq(text.sub(sha("old"), sha("new a")))
    end

    it "raises on a files: entry it finds no sha line for: a quoted nested sha, a flow mapping" do
      quoted = "---\nname: b\nfiles:\n  a.md:\n    sha256: \"sha256:#{sha("old")}\"\n    description: x\n"
      flow = "---\nname: b\nfiles:\n  a.md: {sha256: \"sha256:#{sha("old")}\", description: x}\n  q.md: sha256:#{sha("q")}\n"

      expect { described_class.refresh(dir, quoted) }
        .to raise_error(described_class::Error, %r{b/manifest.yml: no sha line to refresh for files: a.md \(})
      expect { described_class.refresh(dir, flow) }
        .to raise_error(described_class::Error, /no sha line to refresh for files: a.md \(/)
    end

    it "raises on a file the manifest names but the bundle lacks" do
      FileUtils.rm(File.join(dir, "plugin.rb"))
      expect { described_class.refresh(dir, manifest) }.to raise_error(described_class::Error, /names plugin.rb/)
    end

    it "leaves an empty files: {} alone" do
      text = "name: m\nversion: 1.0.0\nfiles: {}\nplugin:\n  file: plugin.rb\n  sha256: sha256:#{sha("p")}\n"
      expect(described_class.refresh(dir, text)).to eq([text, []])
    end
  end

  describe "a sha line's tail" do
    let(:dir) { File.join(tmp, "b") }

    before { write("b/plugin.rb", "p") }

    it "keeps a trailing comment, and a placeholder with one parses" do
      text = "name: b\nplugin:\n  file: plugin.rb\n  sha256: sha256:   # filled by check --fix\n"
      expect(YAML.safe_load(described_class.parseable(text)).dig("plugin", "sha256")).to eq("sha256:0")

      refreshed, changes = described_class.refresh(dir, text)
      expect(changes).to eq([["plugin.rb", "", sha("p")]])
      expect(refreshed).to end_with("  sha256: sha256:#{sha("p")}   # filled by check --fix\n")
      expect(described_class.stale(dir, refreshed)).to eq([])
    end

    it "keeps CRLF line endings on the lines it rewrites" do
      text = "name: b\r\nplugin:\r\n  file: plugin.rb\r\n  sha256: sha256:abc\r\nversion: 0.1.0\r\n"
      refreshed, = described_class.refresh(dir, text)
      expect(refreshed).to eq(text.sub("sha256:abc", "sha256:#{sha("p")}"))
    end
  end

  describe ".stale" do
    let(:dir) { File.join(tmp, "b") }

    before do
      write("b/plugin.rb", "p")
      write("b/hooks/h.rb", "h")
    end

    it "reports a placeholder sha and a wrong hex, and nothing for a current one" do
      write("b/manifest.yml", "name: b\nplugin:\n  file: plugin.rb\n  sha256: sha256:\nhooks:\n  h.rb:\n    sha256: sha256:abc\n")
      expect(described_class.stale(dir)).to eq([described_class::Stale.new("plugin.rb", "", sha("p")),
                                                described_class::Stale.new("hooks/h.rb", "abc", sha("h"))])

      write("b/manifest.yml", described_class.refresh(dir).first)
      expect(described_class.stale(dir)).to eq([])
    end

    it "reports a plugin:, hooks: or scripts: entry with no sha line (the installer takes it unchecked)" do
      write("b/scripts/s.rb", "s")
      write("b/manifest.yml", "name: b\nplugin:\n  file: plugin.rb\nhooks:\n  h.rb:\n    event: after_turn\nscripts:\n  s.rb:\n")

      expect(described_class.stale(dir).map { |s| [s.file, s.old] })
        .to eq([["plugin.rb", nil], ["hooks/h.rb", nil], ["scripts/s.rb", nil]])
    end

    it "raises on a code file the manifest names but the bundle lacks" do
      write("b/manifest.yml", "name: b\nplugin:\n  file: gone.rb\n")
      expect { described_class.stale(dir) }.to raise_error(described_class::Error, /names gone.rb, which isn't there/)
    end
  end
end
