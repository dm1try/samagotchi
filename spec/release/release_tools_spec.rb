# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../../script/release/release_tools"

# The logic behind `rake bundles:*` and `rake release:*` (Rakefile).
RSpec.describe ReleaseTools do
  let(:repo_root) { File.expand_path("../..", __dir__) }
  let(:tmp) { Dir.mktmpdir("release-tools-") }

  after { FileUtils.rm_rf(tmp) }

  def sha(text) = Digest::SHA256.hexdigest(text)

  def write(rel, text)
    path = File.join(tmp, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-C", tmp, "-c", "user.name=x", "-c", "user.email=x@x",
                                  "-c", "init.defaultBranch=main", *args)
    raise out unless status.success?

    out
  end

  describe "the shipped bundles" do
    it "have no stale sha256 lines (edit a bundle file → rake bundles:sha, and bump its version)" do
      expect(described_class.stale_shas(repo_root)).to eq([])
    end

    it "are read in all three manifest shapes: files, hooks and plugin" do
      files = described_class.bundle_dirs(repo_root).to_h do |dir|
        _, changes = described_class.refresh_manifest(File.read(File.join(dir, "manifest.yml")).gsub(/sha256:\h+/, "sha256:0"), dir)
        [File.basename(dir), changes.map(&:first)]
      end
      expect(files).to include("btw" => ["plugin.rb"], "mcp" => ["plugin.rb"], "guardrails" => ["guardrails.md"],
                               "known-names" => ["known_names.md", "hooks/known_names.rb"])
      expect(files["system"]).to include("identity.md", "delegated.md")
    end
  end

  describe ".refresh_manifest" do
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
      text, changes = described_class.refresh_manifest(manifest, dir)
      expect(changes).to eq([["a.md", sha("old"), sha("new a")], ["hooks/h.rb", sha("old"), sha("new h")]])
      expect(text).to eq(manifest.sub("a.md: sha256:#{sha("old")}", "a.md: sha256:#{sha("new a")}")
                                 .sub("sha256: sha256:#{sha("old")}", "sha256: sha256:#{sha("new h")}"))
    end

    it "raises on a file the manifest names but the bundle lacks" do
      FileUtils.rm(File.join(dir, "plugin.rb"))
      expect { described_class.refresh_manifest(manifest, dir) }.to raise_error(ReleaseTools::Error, /names plugin.rb/)
    end

    it "leaves an empty files: {} alone" do
      text = "name: m\nversion: 1.0.0\nfiles: {}\nplugin:\n  file: plugin.rb\n  sha256: sha256:#{sha("p")}\n"
      expect(described_class.refresh_manifest(text, dir)).to eq([text, []])
    end
  end

  describe "bundles in a repository" do
    let(:bundle) { "lib/samagotchi/bundles/b" }

    before do
      write("#{bundle}/a.md", "one")
      write("#{bundle}/manifest.yml", "name: b\nversion: 0.1.0\nfiles:\n  a.md: sha256:#{sha("one")}\n")
      git("init", "-q")
      git("add", ".")
      git("commit", "-q", "-m", "one")
    end

    it "refresh_bundle_shas! rewrites a stale manifest; stale_shas names it before" do
      write("#{bundle}/a.md", "two")
      expect(described_class.stale_shas(tmp)).to eq(["b: stale sha256 for a.md (rake bundles:sha)"])
      expect(described_class.refresh_bundle_shas!(tmp).keys).to eq(["b/manifest.yml"])
      expect(File.read(File.join(tmp, bundle, "manifest.yml"))).to include("a.md: sha256:#{sha("two")}")
      expect(described_class.stale_shas(tmp)).to eq([])
    end

    it "skips the version check, with a note, before the first v* tag" do
      expect(described_class.bundles_check(tmp)).to eq([[], ["No v* tag yet: skipped the changed-bundle version check."]])
    end

    context "after a v* tag" do
      before { git("tag", "v0.1.0") }

      it "passes an unchanged bundle" do
        expect(described_class.bundles_check(tmp)).to eq([[], []])
      end

      it "fails a bundle changed since the tag at the same version, committed or not" do
        write("#{bundle}/a.md", "two")
        described_class.refresh_bundle_shas!(tmp)
        expect(described_class.bundles_check(tmp).first)
          .to eq(["b: changed since v0.1.0 but still version 0.1.0 (bump its manifest version)"])
        git("commit", "-qam", "two")
        expect(described_class.bundles_check(tmp).first.size).to eq(1)
      end

      it "passes a changed bundle with a higher version, and a bundle new since the tag" do
        write("#{bundle}/a.md", "two")
        described_class.refresh_bundle_shas!(tmp)
        path = File.join(tmp, bundle, "manifest.yml")
        File.write(path, File.read(path).sub("version: 0.1.0", "version: 0.1.1"))
        write("lib/samagotchi/bundles/c/manifest.yml", "name: c\nversion: 0.1.0\nfiles: {}\n")
        git("add", ".")
        expect(described_class.bundles_check(tmp)).to eq([[], []])
      end
    end
  end

  describe "CHANGELOG" do
    let(:repo) { "https://example.test/r" }
    let(:unreleased) do
      <<~MD
        # Changelog

        ## [Unreleased]

        ### Added

        - chi.
      MD
    end

    it ".release_changelog turns the first release's Unreleased into a dated section with a tag link" do
      text = described_class.release_changelog(unreleased, "0.2.0", "2026-09-28", repo: repo)
      expect(text).to eq(<<~MD)
        # Changelog

        ## [Unreleased]

        ## [0.2.0] - 2026-09-28

        ### Added

        - chi.

        [Unreleased]: #{repo}/compare/v0.2.0...HEAD
        [0.2.0]: #{repo}/releases/tag/v0.2.0
      MD
    end

    it "a later release compares with the previous one and keeps the older links" do
      first = described_class.release_changelog(unreleased, "0.2.0", "2026-09-28", repo: repo)
      second = first.sub("## [Unreleased]\n", "## [Unreleased]\n\n### Fixed\n\n- a bug.\n")
      text = described_class.release_changelog(second, "0.2.1", "2026-10-01", repo: repo)
      expect(text).to include("## [Unreleased]\n\n## [0.2.1] - 2026-10-01\n\n### Fixed\n\n- a bug.\n\n## [0.2.0] - 2026-09-28")
      expect(text).to end_with(<<~MD)
        [Unreleased]: #{repo}/compare/v0.2.1...HEAD
        [0.2.1]: #{repo}/compare/v0.2.0...v0.2.1
        [0.2.0]: #{repo}/releases/tag/v0.2.0
      MD
      expect(described_class.changelog_section(text, "0.2.1")).to eq("### Fixed\n\n- a bug.")
      expect(described_class.changelog_section(text, "0.2.0")).to eq("### Added\n\n- chi.")
      expect(described_class.changelog_section(text, "Unreleased")).to eq("")
    end

    it "refuses an empty Unreleased, a missing one, and a version released already" do
      expect { described_class.release_changelog("## [Unreleased]\n", "0.2.0", "d") }.to raise_error(ReleaseTools::Error, /empty/)
      expect { described_class.release_changelog("# Changelog\n", "0.2.0", "d") }.to raise_error(ReleaseTools::Error, /no ## \[Unreleased\]/)
      released = described_class.release_changelog(unreleased, "0.2.0", "d", repo: repo).sub("## [Unreleased]\n", "## [Unreleased]\n\n- x\n")
      expect { described_class.release_changelog(released, "0.2.0", "d") }.to raise_error(ReleaseTools::Error, /already/)
    end

    it ".changelog_section is nil for a version it doesn't have" do
      expect(described_class.changelog_section(unreleased, "9.9.9")).to be_nil
    end
  end

  describe ".bump!" do
    before do
      write(ReleaseTools::VERSION_FILE, %(module Samagotchi\n  VERSION = "0.1.37"\nend\n))
      write(ReleaseTools::SYSTEM_MANIFEST, "---\nname: samagotchi-system\nversion: 0.1.37\nfiles: {}\n")
      write("Gemfile.lock", "PATH\n  specs:\n    samagotchi (0.1.37)\n      reline\n\nCHECKSUMS\n  samagotchi (0.1.37)\n  webmock (3.26.2) sha256=ab\n")
      write("lib/samagotchi/bundles/mcp/manifest.yml", "name: mcp\nversion: 0.3.1\nrequires_chi: \">= 0.1.37\"\n")
      write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n- chi.\n")
    end

    def read(rel) = File.read(File.join(tmp, rel))

    it "moves VERSION, the system manifest, Gemfile.lock and the CHANGELOG; never a requires_chi" do
      expect(described_class.bump!(tmp, "0.2.0", date: "2026-09-28")).to eq("0.1.37")
      expect(described_class.gem_version(tmp)).to eq("0.2.0")
      expect(described_class.system_bundle_version(tmp)).to eq("0.2.0")
      expect(read("Gemfile.lock")).to eq("PATH\n  specs:\n    samagotchi (0.2.0)\n      reline\n\nCHECKSUMS\n  samagotchi (0.2.0)\n  webmock (3.26.2) sha256=ab\n")
      expect(read("CHANGELOG.md")).to include("## [0.2.0] - 2026-09-28\n\n- chi.")
      expect(read("lib/samagotchi/bundles/mcp/manifest.yml")).to include('">= 0.1.37"')
    end

    it "refuses a malformed or lower version, and changes nothing then" do
      expect { described_class.bump!(tmp, "v0.2.0") }.to raise_error(ReleaseTools::Error, /isn't a version/)
      expect { described_class.bump!(tmp, "0.1.9") }.to raise_error(ReleaseTools::Error, /isn't above/)
      expect(described_class.gem_version(tmp)).to eq("0.1.37")
    end

    it "changes nothing when the CHANGELOG can't be released" do
      write("CHANGELOG.md", "## [Unreleased]\n")
      expect { described_class.bump!(tmp, "0.2.0") }.to raise_error(ReleaseTools::Error, /empty/)
      expect([described_class.gem_version(tmp), read("Gemfile.lock")]).to all(include("0.1.37"))
    end
  end

  describe ".draft_changelog" do
    it "groups subjects into Added / Changed / Fixed and drops merges and version bumps" do
      draft = described_class.draft_changelog([
        "Add chi --version", "chi --version prints \"chi <version>\" (it said \"version unknown\" and exited 1)",
        "Merge branch 'x'", "System bundle and gem 0.1.37", "web: the composer grows with its text",
        "Fix the stale badge after a reload"
      ])
      expect(draft).to eq(<<~MD)
        ## [Unreleased]

        ### Added

        - Add chi --version

        ### Changed

        - web: the composer grows with its text

        ### Fixed

        - chi --version prints "chi <version>" (it said "version unknown" and exited 1)
        - Fix the stale badge after a reload
      MD
    end
  end

  describe ".consistency_problems" do
    before do
      write(ReleaseTools::VERSION_FILE, %(VERSION = "0.2.0"\n))
      write(ReleaseTools::SYSTEM_MANIFEST, "version: 0.2.0\n")
      write("CHANGELOG.md", "## [Unreleased]\n\n## [0.2.0] - 2026-09-28\n\n- chi.\n")
      git("init", "-q")
      git("add", ".")
      git("commit", "-q", "-m", "one")
    end

    it "is empty for a clean, consistent tree (untracked files don't count)" do
      write("scratch.txt", "x")
      expect(described_class.consistency_problems(tmp)).to eq([])
    end

    it "names a dirty tracked file, a version mismatch and a missing CHANGELOG section" do
      write(ReleaseTools::SYSTEM_MANIFEST, "version: 0.1.37\n")
      write("CHANGELOG.md", "## [Unreleased]\n")
      problems = described_class.consistency_problems(tmp)
      expect(problems.size).to eq(3)
      expect(problems.join("\n")).to include("uncommitted changes", "VERSION 0.2.0 != system bundle 0.1.37",
                                             "no (or an empty) ## [0.2.0] section")
    end
  end
end
