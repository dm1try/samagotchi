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

    it "keep each profile's requires_chi at its members' highest (bundles:check notes one below)" do
      expect(described_class.low_meta_floors(repo_root)).to eq([])
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

    # An install takes only the files: a non-empty list names
    # (MemoryBundle::MemoryFiles), so an unlisted memory would never install.
    it "unlisted_memories names a shipped *.md that files: leaves out; bundles_check fails on it" do
      write("#{bundle}/b.md", "other")
      expect(described_class.unlisted_memories(tmp))
        .to eq(["b: ships b.md, which files: doesn't list (an install leaves it out; add it, then rake bundles:sha)"])
      expect(described_class.bundles_check(tmp).first).to include(a_string_matching(/b: ships b\.md/))
    end

    # A profile's floor guards nothing at install (each member checks its
    # own), so one below a member's is a note, not a failure.
    it "notes a meta bundle whose requires_chi is below a member's, naming the highest" do
      write("lib/samagotchi/bundles/m1/manifest.yml", "name: m1\nversion: 0.1.0\nrequires_chi: \">= 0.3.0\"\nfiles: {}\n")
      write("lib/samagotchi/bundles/m2/manifest.yml", "name: m2\nversion: 0.1.0\nrequires_chi: \">= 0.2.0, < 1.0\"\nfiles: {}\n")
      write("lib/samagotchi/bundles/p/manifest.yml",
            "name: p\nversion: 0.1.0\nrequires_chi: \">= 0.2.0\"\nincludes:\n- m2\n- m1\n- gone\n")
      note = "p: requires_chi \">= 0.2.0\" is below member m1's \">= 0.3.0\": raise it to \">= 0.3.0\" (and bump p's version)"
      expect(described_class.low_meta_floors(tmp)).to eq([note])
      expect(described_class.bundles_check(tmp)).to eq([[], [note, "No v* tag yet: skipped the changed-bundle version check."]])

      path = File.join(tmp, "lib/samagotchi/bundles/p/manifest.yml")
      File.write(path, File.read(path).sub(">= 0.2.0", ">= 0.3.0"))
      expect(described_class.low_meta_floors(tmp)).to eq([])
      File.write(path, File.read(path).sub("requires_chi: \">= 0.3.0\"\n", ""))
      expect(described_class.low_meta_floors(tmp)).to eq([note.sub("\">= 0.2.0\" is", "(none) is")])
    end

    it "skips the version check, with a note, before the first v* tag" do
      expect(described_class.bundles_check(tmp)).to eq([[], ["No v* tag yet: skipped the changed-bundle version check."]])
    end

    context "after a v* tag" do
      before { git("tag", "v0.1.0") }

      it "passes an unchanged bundle" do
        git("commit", "-q", "--allow-empty", "-m", "after the tag")
        expect(described_class.bundles_check(tmp)).to eq([[], []])
      end

      # The release workflow runs on the tag being released, at HEAD.
      it "compares with the tag before the one on HEAD" do
        write("#{bundle}/a.md", "two")
        described_class.refresh_bundle_shas!(tmp)
        git("commit", "-qam", "two")
        git("tag", "v0.2.0")
        expect(described_class.last_tag(tmp)).to eq("v0.1.0")
        expect(described_class.bundles_check(tmp).first)
          .to eq(["b: changed since v0.1.0 but still version 0.1.0 (bump its manifest version)"])
      end

      it "finds no tag when the only one is on HEAD and nothing changed since; with edits, that tag" do
        expect(described_class.last_tag(tmp)).to be_nil
        write("#{bundle}/a.md", "two")
        expect(described_class.last_tag(tmp)).to eq("v0.1.0")
      end

      it "fails a bundle changed since the tag at the same version, committed or not" do
        write("#{bundle}/a.md", "two")
        described_class.refresh_bundle_shas!(tmp)
        expect(described_class.bundles_check(tmp).first)
          .to eq(["b: changed since v0.1.0 but still version 0.1.0 (bump its manifest version)"])
        git("commit", "-qam", "two")
        expect(described_class.bundles_check(tmp).first.size).to eq(1)
      end

      it "passes a bundle whose spec/ alone changed: its specs aren't installed" do
        write("#{bundle}/spec/b_spec.rb", "# a spec")
        git("add", ".")
        git("commit", "-qm", "a spec")
        expect(described_class.bundles_check(tmp, ci: true)).to eq([[], []])
        write("#{bundle}/a.md", "two")
        described_class.refresh_bundle_shas!(tmp)
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

      # A warning, not a failure: most bundle changes need nothing new from chi.
      context "with a requires_chi" do
        before do
          path = File.join(tmp, bundle, "manifest.yml")
          File.write(path, File.read(path).sub("files:", "requires_chi: \">= 0.1.0\"\nfiles:"))
          git("commit", "-qam", "requires_chi")
          git("tag", "-f", "v0.1.0")
        end

        def change_bundle(requires_chi)
          write("#{bundle}/a.md", "two")
          described_class.refresh_bundle_shas!(tmp)
          path = File.join(tmp, bundle, "manifest.yml")
          File.write(path, File.read(path).sub("version: 0.1.0", "version: 0.1.1")
                                          .sub(/requires_chi: .*$/, "requires_chi: \"#{requires_chi}\""))
        end

        it "warns about a changed bundle whose requires_chi the last tag's chi already meets" do
          change_bundle(">= 0.1.0")
          expect(described_class.bundles_check(tmp)).to eq(
            [[], ["b: changed since v0.1.0 and requires_chi \">= 0.1.0\" admits that chi: " \
                  "mark it requires_chi_next if the change uses anything newer"]]
          )
        end

        it "is quiet for a meta bundle: installing it checks each member's own requires_chi" do
          change_bundle(">= 0.1.0")
          path = File.join(tmp, bundle, "manifest.yml")
          File.write(path, "#{File.read(path)}includes:\n- other\n")
          expect(described_class.bundles_check(tmp)).to eq([[], []])
        end

        it "notes a requires_chi_next marker instead of warning, and passes with it (main keeps loading the bundle)" do
          change_bundle(">= 0.1.0")
          path = File.join(tmp, bundle, "manifest.yml")
          File.write(path, "#{File.read(path)}requires_chi_next: true\n")
          expect(described_class.bundles_check(tmp, ci: true))
            .to eq([[], ["b: requires_chi_next is set: rake release:bump raises its requires_chi"]])
          expect(described_class.bundles_check(tmp).first).to eq([])
        end

        it "fails a requires_chi_next that isn't true or a one-line reason" do
          change_bundle(">= 0.1.0")
          path = File.join(tmp, bundle, "manifest.yml")
          File.write(path, "#{File.read(path)}requires_chi_next: [x]\n")
          expect(described_class.bundles_check(tmp).first)
            .to eq(["b: requires_chi_next: must be `true` or a one-line reason, on its own top-level line"])
          File.write(path, File.read(path).sub("requires_chi_next: [x]\n", "requires_chi_next: >\n  a reason\n"))
          expect(described_class.bundles_check(tmp).first.size).to eq(1)
          File.write(path, File.read(path).sub("requires_chi_next: >\n  a reason\n", "requires_chi_next: false\n"))
          expect(described_class.bundles_check(tmp).first).to eq([])
        end

        it "is quiet when the changed bundle requires a newer chi, or the bundle didn't change" do
          git("commit", "-q", "--allow-empty", "-m", "after the tag")
          expect(described_class.bundles_check(tmp)).to eq([[], []])
          change_bundle(">= 0.1.1")
          expect(described_class.bundles_check(tmp)).to eq([[], []])
        end
      end

      # Between releases the system bundle is changed at its tagged version:
      # release:bump moves it with VERSION.
      context "in CI mode" do
        let(:system) { "lib/samagotchi/bundles/system" }

        before do
          write("#{system}/s.md", "one")
          write("#{system}/manifest.yml", "name: system\nversion: 0.1.0\nfiles:\n  s.md: sha256:#{sha("one")}\n")
          git("add", ".")
          git("commit", "-q", "-m", "system")
          git("tag", "-f", "v0.1.0")
          write("#{system}/s.md", "two")
          described_class.refresh_bundle_shas!(tmp)
        end

        it "passes the system bundle changed since the tag at its version; the full check fails it" do
          expect(described_class.bundles_check(tmp, ci: true)).to eq([[], []])
          expect(described_class.bundles_check(tmp).first)
            .to eq(["system: changed since v0.1.0 but still version 0.1.0 (bump its manifest version)"])
        end

        it "still fails another bundle changed without a bump, and a stale sha line in any bundle" do
          write("#{bundle}/a.md", "two")
          described_class.refresh_bundle_shas!(tmp)
          expect(described_class.bundles_check(tmp, ci: true).first)
            .to eq(["b: changed since v0.1.0 but still version 0.1.0 (bump its manifest version)"])
          write("#{system}/s.md", "three")
          expect(described_class.bundles_check(tmp, ci: true).first)
            .to include("system: stale sha256 for s.md (rake bundles:sha)")
        end
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
      expect(described_class.bump!(tmp, "0.2.0", date: "2026-09-28"))
        .to eq(ReleaseTools::Bumped.new(old: "0.1.37", raised: [], profiles: []))
      expect(described_class.gem_version(tmp)).to eq("0.2.0")
      expect(described_class.system_bundle_version(tmp)).to eq("0.2.0")
      expect(read("Gemfile.lock")).to eq("PATH\n  specs:\n    samagotchi (0.2.0)\n      reline\n\nCHECKSUMS\n  samagotchi (0.2.0)\n  webmock (3.26.2) sha256=ab\n")
      expect(read("CHANGELOG.md")).to include("## [0.2.0] - 2026-09-28\n\n- chi.")
      expect(read("lib/samagotchi/bundles/mcp/manifest.yml")).to include('">= 0.1.37"')
    end

    it "raises a marked bundle's requires_chi to the new version and drops the marker; leaves the others" do
      write("lib/samagotchi/bundles/btw/manifest.yml", "name: btw\nversion: 0.1.2\nrequires_chi_next: the new hook\nplugin:\n  file: p.rb\n")
      write("lib/samagotchi/bundles/mcp/manifest.yml",
            "name: mcp\nversion: 0.3.1\nrequires_chi: \">= 0.1.37\"\nrequires_chi_next: true\n")
      write("lib/samagotchi/bundles/skills/manifest.yml", "name: skills\nversion: 0.1.0\nrequires_chi: \">= 0.1.30\"\n")
      described_class.bump!(tmp, "0.2.0", date: "2026-09-28")
      expect(read("lib/samagotchi/bundles/btw/manifest.yml"))
        .to eq("name: btw\nversion: 0.1.2\nrequires_chi: \">= 0.2.0\"\nplugin:\n  file: p.rb\n")
      expect(read("lib/samagotchi/bundles/mcp/manifest.yml")).to eq("name: mcp\nversion: 0.3.1\nrequires_chi: \">= 0.2.0\"\n")
      expect(read("lib/samagotchi/bundles/skills/manifest.yml")).to include('">= 0.1.30"')
      expect(described_class.requires_chi_next(tmp)).to be_empty
    end

    # The dev profile 0.7.2 by hand at 0.107.0 (its member coordinator was
    # raised): release:bump raises a profile left below a member with it.
    it "raises a profile left below a raised member to that member's floor, with a patch bump of its version" do
      write("lib/samagotchi/bundles/coord/manifest.yml", "name: coord\nversion: 0.6.0\nrequires_chi: \">= 0.1.30\"\nrequires_chi_next: true\n")
      write("lib/samagotchi/bundles/dev/manifest.yml",
            "---\nname: dev\nversion: 0.7.1\nrequires_chi: \">= 0.1.37\"\nincludes:\n- mcp\n- coord\n")
      write("lib/samagotchi/bundles/bare/manifest.yml", "name: bare\nversion: 0.1.0\nincludes:\n- coord\n")
      write("lib/samagotchi/bundles/core/manifest.yml",
            "name: core\nversion: 0.2.0\nrequires_chi: \">= 0.1.37\"\nincludes:\n- mcp\n")
      bumped = described_class.bump!(tmp, "0.2.0", date: "2026-09-28")
      expect(bumped.raised).to eq(["coord"])
      expect(bumped.profiles).to eq([ReleaseTools::RaisedProfile.new(name: "bare", old_version: "0.1.0", version: "0.1.1", floor: "0.2.0"),
                                     ReleaseTools::RaisedProfile.new(name: "dev", old_version: "0.7.1", version: "0.7.2", floor: "0.2.0")])
      expect(read("lib/samagotchi/bundles/dev/manifest.yml"))
        .to eq("---\nname: dev\nversion: 0.7.2\nrequires_chi: \">= 0.2.0\"\nincludes:\n- mcp\n- coord\n")
      expect(read("lib/samagotchi/bundles/bare/manifest.yml"))
        .to eq("name: bare\nversion: 0.1.1\nrequires_chi: \">= 0.2.0\"\nincludes:\n- coord\n")
      expect(read("lib/samagotchi/bundles/core/manifest.yml")).to include("version: 0.2.0\nrequires_chi: \">= 0.1.37\"")
      expect(described_class.low_meta_floors(tmp)).to eq([])
    end

    # A profile in a profile: raising dev (its member coord was raised)
    # leaves all, which includes dev, below dev until a second pass.
    it "raises a profile whose member profile it raised, until none is left below a member" do
      write("lib/samagotchi/bundles/coord/manifest.yml", "name: coord\nversion: 0.6.0\nrequires_chi_next: true\n")
      write("lib/samagotchi/bundles/dev/manifest.yml", "name: dev\nversion: 0.7.1\nrequires_chi: \">= 0.1.37\"\nincludes:\n- coord\n")
      write("lib/samagotchi/bundles/all/manifest.yml", "name: all\nversion: 1.0.0\nrequires_chi: \">= 0.1.37\"\nincludes:\n- dev\n")
      bumped = described_class.bump!(tmp, "0.2.0", date: "2026-09-28")
      expect(bumped.profiles).to eq([ReleaseTools::RaisedProfile.new(name: "all", old_version: "1.0.0", version: "1.0.1", floor: "0.2.0"),
                                     ReleaseTools::RaisedProfile.new(name: "dev", old_version: "0.7.1", version: "0.7.2", floor: "0.2.0")])
      expect(read("lib/samagotchi/bundles/all/manifest.yml"))
        .to eq("name: all\nversion: 1.0.1\nrequires_chi: \">= 0.2.0\"\nincludes:\n- dev\n")
      expect(read("lib/samagotchi/bundles/dev/manifest.yml")).to include("version: 0.7.2\n")
      expect(described_class.low_meta_floors(tmp)).to eq([])
    end

    # A member joined dev this release (dev 0.7.1 -> 0.7.2 by hand) and
    # another one's marker raises dev's floor: one release, one bump.
    it "raises a profile's floor but keeps its version when it already moved since the last tag" do
      write("lib/samagotchi/bundles/coord/manifest.yml", "name: coord\nversion: 0.6.0\nrequires_chi_next: true\n")
      write("lib/samagotchi/bundles/dev/manifest.yml", "name: dev\nversion: 0.7.1\nrequires_chi: \">= 0.1.37\"\nincludes:\n- coord\n")
      write("lib/samagotchi/bundles/core/manifest.yml", "name: core\nversion: 0.2.0\nincludes:\n- coord\n")
      git("init", "-q")
      git("add", ".")
      git("commit", "-q", "-m", "one")
      git("tag", "v0.1.37")
      write("lib/samagotchi/bundles/dev/manifest.yml",
            "name: dev\nversion: 0.7.2\nrequires_chi: \">= 0.1.37\"\nincludes:\n- coord\n- mcp\n")
      write("lib/samagotchi/bundles/fresh/manifest.yml", "name: fresh\nversion: 0.1.0\nincludes:\n- coord\n")

      bumped = described_class.bump!(tmp, "0.2.0", date: "2026-09-28")
      expect(bumped.profiles.map { |p| [p.name, p.old_version, p.version] })
        .to eq([%w[core 0.2.0 0.2.1], %w[dev 0.7.2 0.7.2], %w[fresh 0.1.0 0.1.0]])
      expect(read("lib/samagotchi/bundles/dev/manifest.yml"))
        .to eq("name: dev\nversion: 0.7.2\nrequires_chi: \">= 0.2.0\"\nincludes:\n- coord\n- mcp\n")
    end

    describe "naming the raised profiles in the CHANGELOG's `chi update` line" do
      def bump_with(changelog_body)
        write(ReleaseTools::VERSION_FILE, %(module Samagotchi\n  VERSION = "0.1.37"\nend\n))
        write(ReleaseTools::SYSTEM_MANIFEST, "---\nname: samagotchi-system\nversion: 0.1.37\nfiles: {}\n")
        write("Gemfile.lock", "PATH\n  specs:\n    samagotchi (0.1.37)\n")
        write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n#{changelog_body}\n## [0.1.37] - 2026-09-01\n\n- old.\n" \
                              "Update with `chi update` (the dev profile 0.7.0).\n")
        write("lib/samagotchi/bundles/coord/manifest.yml", "name: coord\nversion: 0.6.0\nrequires_chi_next: true\n")
        write("lib/samagotchi/bundles/dev/manifest.yml", "name: dev\nversion: 0.7.1\nincludes:\n- coord\n")
        described_class.bump!(tmp, "0.2.0", date: "2026-09-28")
        described_class.changelog_section(read("CHANGELOG.md"), "0.2.0")
      end

      it "adds it inside the line's parentheses, or replaces the version it names there" do
        expect(bump_with("- chi.\n\nUpdate with `chi update` (the system bundle 0.2.0), then restart `chi web`.\n"))
          .to eq("- chi.\n\nUpdate with `chi update` (the system bundle 0.2.0, the dev profile 0.7.2), then restart `chi web`.")
        expect(bump_with("- chi.\n\nUpdate with `chi update` (the dev profile 0.7.1, mcp 0.3.1).\n"))
          .to eq("- chi.\n\nUpdate with `chi update` (the dev profile 0.7.2, mcp 0.3.1).")
      end

      it "finds the line inside a bullet, wrapped too, when the section has none of its own" do
        expect(bump_with("- guardrails (0.9.3): a fix. Update with `chi update`.\n- mcp: a fix. Update with\n  `chi update` (mcp 0.3.2).\n"))
          .to eq("- guardrails (0.9.3): a fix. Update with `chi update` (the dev profile 0.7.2).\n" \
                 "- mcp: a fix. Update with\n  `chi update` (mcp 0.3.2).")
        expect(bump_with("- mcp: a fix. Update with\n  `chi update` (mcp 0.3.2).\n"))
          .to eq("- mcp: a fix. Update with `chi update` (mcp 0.3.2, the dev profile 0.7.2).")
        expect(bump_with("- mcp: a fix. Update with `chi update`.\n\nUpdate with `chi update`, then restart `chi web`.\n"))
          .to eq("- mcp: a fix. Update with `chi update`.\n\nUpdate with `chi update` (the dev profile 0.7.2), then restart `chi web`.")
      end

      it "gives a bare line parentheses, and a section without one the line" do
        expect(bump_with("- chi.\n\nUpdate with `chi update`.\n")).to eq("- chi.\n\nUpdate with `chi update` (the dev profile 0.7.2).")
        expect(bump_with("- chi.\n")).to eq("- chi.\n\nUpdate with `chi update` (the dev profile 0.7.2).")
        expect(read("CHANGELOG.md")).to include("(the dev profile 0.7.2).\n\n## [0.1.37] - 2026-09-01\n\n- old.\n" \
                                                "Update with `chi update` (the dev profile 0.7.0).\n")
      end
    end

    it "changes nothing when a profile to raise has a version it can't patch-bump" do
      write("lib/samagotchi/bundles/coord/manifest.yml", "name: coord\nversion: 0.6.0\nrequires_chi_next: true\n")
      write("lib/samagotchi/bundles/dev/manifest.yml", "name: dev\nversion: 0.7\nincludes:\n- coord\n")
      expect { described_class.bump!(tmp, "0.2.0") }.to raise_error(ReleaseTools::Error, /dev: version "0.7" isn't x.y.z/)
      expect([described_class.gem_version(tmp), read("lib/samagotchi/bundles/coord/manifest.yml")])
        .to eq(["0.1.37", "name: coord\nversion: 0.6.0\nrequires_chi_next: true\n"])
    end

    it "changes nothing when a marker can't be rewritten" do
      write("lib/samagotchi/bundles/mcp/manifest.yml", "name: mcp\nversion: 0.3.1\nrequires_chi_next: [1]\n")
      expect { described_class.bump!(tmp, "0.2.0") }.to raise_error(ReleaseTools::Error, /mcp: requires_chi_next: must be/)
      expect([described_class.gem_version(tmp), read("CHANGELOG.md")]).to eq(["0.1.37", "# Changelog\n\n## [Unreleased]\n\n- chi.\n"])
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

    it "names a bundle still marked requires_chi_next: the release didn't raise its requires_chi" do
      write("lib/samagotchi/bundles/b/manifest.yml", "name: b\nversion: 0.1.0\nrequires_chi_next: true\n")
      git("add", ".")
      git("commit", "-q", "-m", "marker")
      expect(described_class.consistency_problems(tmp)).to eq(
        ["b: requires_chi_next is still set: raise its requires_chi to \">= 0.2.0\" and drop the marker " \
         "(rake release:bump does both)"]
      )
    end

    it "names the remote attach's temporary refusals while RemoteLink::NOT_YET is defined" do
      write(ReleaseTools::REMOTE_LINK, "class RemoteLink\n  NOT_YET = \"(%s isn't available)\"\nend\n")
      git("add", ".")
      git("commit", "-q", "-m", "not yet")
      expect(described_class.consistency_problems(tmp)).to eq([described_class.remote_not_yet_problem])

      write(ReleaseTools::REMOTE_LINK, "class RemoteLink\nend\n")
      git("commit", "-q", "-am", "done")
      expect(described_class.consistency_problems(tmp)).to eq([])
    end
  end
end
