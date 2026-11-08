# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"
require "yaml"

require "samagotchi/bundle_command"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/uninstaller"
require "samagotchi/memory_bundle/remerge"
require "samagotchi/memory_bundle/system_bundle"
require "samagotchi/memory_bundle/shipped_update"
require "samagotchi/memory_bundle/listing"
require "samagotchi/memory_bundle/status"
require "samagotchi/memory_bundle/file_standing"
require "samagotchi/memory_bundle/shipped_history"

# The bundle-state corpus (spec/fixtures/bundle_states): each case is one
# bundle file in a known state, run through every command of a spec file's
# group, once per record shape. A cell is what a user or the next command
# sees afterwards: the bytes, the trash, the record and base, the summary's
# word, the warnings, chi bundle status's label. Never the Installer's result
# strings (P1.2 replaces them).
#
# Each case's starting tree is written directly (no Installer run builds it)
# into a template, once per shape and flavor; every command runs on a copy.
# The expectations (expect/<file>.yml) are generated with UPDATE_GOLDENS=1.
module BundleStateCorpus
  FIXTURES = File.expand_path("../../../fixtures/bundle_states", __dir__)
  TMP = File.expand_path("../../../../tmp/bundle_states", __dir__)
  # The record shapes: 0.155's (today's Provenance#write) and 0.149's: a mark
  # is a bare conflict: true (no incoming_sha, why, legacy_base), no kept
  # manifest.yml, manifest_sha or installed_by, no incoming/ texts.
  SHAPES = %w[0.155 0.149].freeze
  KINDS = %w[new missing user_same user_file level pristine pristine_no_base edited diverged edited_no_base
             dropped_pristine dropped_edited dropped_missing unreadable].freeze
  # The text a mark speaks of when the source moved since (marked_incoming: older).
  OLDER = "o\nl\nd\n"
  # The text a recorded: other checksum is of.
  OTHER = "other\n"
  WRONG = "wrong\n"
  NAME = "demo"
  SYSTEM = Samagotchi::MemoryBundle::SystemBundle::BUNDLE_NAME
  CLAIMANT_SOURCE = "/nowhere/other"
  # A plan reads a record as chi's when its source looks shipped (ShippedUpdate.from_chi?).
  SHIPPED_LOOKING = "/corpus/lib/samagotchi/bundles/#{NAME}".freeze
  # The commands that run on the record named samagotchi-system at the
  # shipped version; the rest on demo, a version behind its source.
  SYSTEM_COLUMNS = %w[remerge remerge_dry restore].freeze
  # Each memory spec file's columns: the commands it runs every case through.
  MEMORY_GROUPS = {
    "install" => %w[install install_force install_dry],
    "upgrade" => %w[upgrade upgrade_force upgrade_dry],
    "plan" => %w[plan],
    "remerge_restore" => %w[remerge remerge_dry restore],
    "uninstall_status" => %w[uninstall uninstall_force status]
  }.freeze
  # The plan's time fallback (2.6): these files run the 0.149 shape for the
  # marked cases only, where the shapes can differ (invariant 2); an unmarked
  # case's one cell stands for both. upgrade_spec ran over 3 s under load.
  MARKED_ONLY_149 = %w[upgrade].freeze

  MemoryCase = Data.define(:id, :kind, :installed, :owned, :key, :base, :disk, :incoming, :recorded, :sha, :mark,
                           :marked_incoming, :shipped_history, :claimants, :unreadable, :fix, :fixed, :divergent, :changed, :note) do
    def marked? = mark != "none"

    # Whether the file holds bytes of the user's: there, not the bundle's
    # incoming text, and not vouched for by the record as D1 reads it
    # (Provenance.unchanged?: the checksum first, then the base).
    def users_bytes?
      return false if disk.nil? || disk == incoming

      vouched = recorded == "disk" || (recorded == "base" && disk == base) || (recorded == "none" && disk == base)
      !vouched
    end

    def marked_text = marked_incoming == "older" || incoming.nil? ? OLDER : incoming
  end

  module_function

  def memory_data = @memory_data ||= YAML.safe_load_file(File.join(FIXTURES, "memory_cases.yml"))

  # The cases, defaults filled in and text names resolved.
  def memory_cases
    @memory_cases ||= begin
      texts = memory_data.fetch("texts")
      text = ->(name) { name.nil? ? nil : texts.fetch(name) }
      memory_data.fetch("cases").map do |row|
        base = text.call(row["base"])
        MemoryCase.new(
          id: row.fetch("id"), kind: row.fetch("kind"), installed: row.fetch("installed", true),
          owned: row.fetch("owned", true), key: row.fetch("key", "a.md"), base: base,
          disk: text.call(row["disk"]), incoming: text.call(row["incoming"]),
          recorded: row.fetch("recorded", default_recorded(base, row["disk"])), sha: row.fetch("sha", "right"),
          mark: row.fetch("mark", "none"), marked_incoming: row.fetch("marked_incoming", "incoming"),
          shipped_history: row.fetch("shipped_history", false), claimants: row.fetch("claimants", []),
          unreadable: row.fetch("unreadable", false), fix: row.fetch("fix", []), fixed: row["fixed"],
          divergent: row["divergent"], changed: row["changed"], note: row["note"]
        )
      end
    end
  end

  def sha(text) = Digest::SHA256.hexdigest(text)

  # A case's checksum when it names none: the base's, else the file's, else none.
  def default_recorded(base, disk)
    return "base" if base

    disk ? "disk" : "none"
  end

  # XDG_CONFIG_HOME at +dir+ for the block (memories, .bundles, the trash).
  def at_home(dir)
    saved = ENV.fetch("XDG_CONFIG_HOME", nil)
    ENV["XDG_CONFIG_HOME"] = dir
    yield
  ensure
    ENV["XDG_CONFIG_HOME"] = saved
  end

  def with_env(vars)
    saved = vars.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved&.each { |key, value| ENV[key] = value }
  end

  def memories_dir = Samagotchi::MemoryPaths.system_dir
  def bundles_dir = Samagotchi::MemoryPaths.bundles_dir

  # The case's trees for one spec file: its sources (shared, never written by
  # a command) and its templates, built on first use.
  class Sandbox
    attr_reader :root

    def initialize
      @root = File.realpath(Dir.mktmpdir("bundle-states-"))
      @templates = {}
      @runs = 0
    end

    # The runs stay until here (one rm for the file's thousands of small files).
    def cleanup = system("rm", "-rf", @root, exception: false) || FileUtils.rm_rf(@root)

    # Paths and timestamps out of a line: what differs per run.
    def mask(line)
      line.to_s.gsub(%r{#{Regexp.escape(@root)}/runs/\d+}, "<home>").gsub(%r{#{Regexp.escape(@root)}/src/[^/]+}, "<src>")
          .gsub(@root, "<tmp>").gsub(/-\d{8}-\d{6}(-\d+)?/, "-<stamp>").gsub(/\d{4}-\d\d-\d\d \d\d:\d\d/, "<time>")
    end

    # The source a demo command installs from: version 1.1.0, the case's
    # incoming text (nothing when the bundle dropped the file). Its parent is
    # the shipped dir a plan reads.
    def source(kase) = build_source(kase, "v2", NAME, "1.1.0")

    # The shipped system bundle at the record's version (Remerge, restore).
    def same_source(kase) = build_source(kase, "same", SYSTEM, "1.0.0")

    # The bundle as first installed (its manifest.yml is the kept one).
    def first_source(kase) = build_source(kase, "v1", NAME, "1.0.0", text: kase.base || kase.disk)

    # A copy of the case's starting tree for +column+, as XDG_CONFIG_HOME.
    def run_copy(kase, shape, column)
      flavor = SYSTEM_COLUMNS.include?(column) ? :system : :demo
      files = (@templates[[kase.id, shape, flavor]] ||= read_tree(build_template(kase, shape, flavor)))
      run = File.join(@root, "runs", (@runs += 1).to_s)
      FileUtils.mkdir_p(run)
      # Sorted, so a dir comes before what is in it.
      files.each do |rel, entry|
        path = File.join(run, rel)
        case entry
        when nil then Dir.mkdir(path)
        when Array then File.symlink(entry.last, path)
        else File.binwrite(path, entry)
        end
      end
      run
    end

    private

    # The template as relative path => its bytes, nil for a dir (kept even
    # when empty), [:link, target] for a symlink (a dev install's): a run
    # writes them, cheaper than cp_r.
    def read_tree(dir)
      Dir.glob("**/*", File::FNM_DOTMATCH, base: dir).sort.reject { |rel| rel.end_with?("/.") || rel == "." }.to_h do |rel|
        path = File.join(dir, rel)
        [rel, if File.symlink?(path) then [:link, File.readlink(path)]
              elsif File.file?(path) then File.binread(path)
              end]
      end
    end

    def build_source(kase, label, name, version, text: kase.incoming)
      dir = File.join(@root, "src", kase.id, label, name)
      return dir if File.directory?(dir)

      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, kase.key), text) if text
      files = text ? { kase.key => listed_sha(kase, text) } : {}
      manifest = { "name" => name, "version" => version, "scope" => "system" }
      manifest["files"] = files unless files.empty?
      File.write(File.join(dir, "manifest.yml"), YAML.dump(manifest))
      dir
    end

    def listed_sha(kase, text)
      case kase.sha
      when "right" then "sha256:#{BundleStateCorpus.sha(text)}"
      when "wrong" then "sha256:#{BundleStateCorpus.sha(WRONG)}"
      else ""
      end
    end

    def build_template(kase, shape, flavor)
      home = File.join(@root, "templates", kase.id, shape, flavor.to_s)
      FileUtils.mkdir_p(File.join(home, "samagotchi"))
      FileUtils.cp(File.join(SPEC_XDG_CONFIG_HOME, "samagotchi", "config.yml"), File.join(home, "samagotchi", "config.yml"))
      BundleStateCorpus.at_home(home) do
        name = flavor == :system ? SYSTEM : NAME
        FileUtils.mkdir_p(BundleStateCorpus.memories_dir)
        write_claimants(kase)
        write_disk(kase, name)
        write_record(kase, name, flavor) if kase.installed
        Shapes.v149!(BundleStateCorpus.bundles_dir) if shape == "0.149"
      end
      home
    end

    def write_disk(kase, name)
      return unless kase.disk

      File.write(File.join(BundleStateCorpus.memories_dir, kase.key), kase.disk)
      return if kase.key.match?(Samagotchi::ModelOverlay::OVERLAY_SUFFIX_PATTERN)

      owner = kase.owned && kase.installed ? name : nil
      Samagotchi::MemoryBundle::IndexUpdater.update_index("system", kase.key.delete_suffix(".md"), kase.disk.bytesize, nil, source: owner)
    end

    def write_claimants(kase)
      kase.claimants.each do |other|
        from = scratch_file("claimant-#{kase.id}", kase.disk || kase.base || kase.incoming)
        Samagotchi::MemoryBundle::Provenance.new(name: other)
                                            .write(files: { kase.key => from }, scope: "system", version: "1.0.0", source_path: CLAIMANT_SOURCE)
      end
    end

    # Today's Provenance#write, then the entry's checksum and base as the case
    # says, a mark's words as chi writes them, and legacy_base.
    def write_record(kase, name, flavor)
      source = flavor == :system ? same_source(kase) : source(kase)
      kept = flavor == :system ? source : first_source(kase)
      files = kase.owned ? { kase.key => kase.base && scratch_file("base-#{kase.id}", kase.base) } : {}
      marks = kase.owned && kase.marked? ? [Samagotchi::MemoryBundle::FileStanding::Behind.new(file: kase.key, version: "1.0.0")] : []
      incoming_dir = marks.empty? ? nil : File.dirname(scratch_file("marked-#{kase.id}/#{kase.key}", kase.marked_text))
      provenance = Samagotchi::MemoryBundle::Provenance.new(name: name)
      provenance.write(files: files, scope: "system", version: "1.0.0", source_path: source, marks: marks,
                       incoming_dir: incoming_dir, manifest_from: kept)
      return unless kase.owned

      path = File.join(provenance.bundle_dir, "manifest.json")
      raw = JSON.parse(File.read(path))
      entry = raw["files"].fetch(kase.key)
      case kase.recorded
      when "disk" then entry["checksum"] = BundleStateCorpus.sha(kase.disk)
      when "other" then entry["checksum"] = BundleStateCorpus.sha(OTHER)
      when "none" then entry.delete("checksum")
      end
      File.write(path, JSON.pretty_generate(raw))
      return unless kase.marked?

      provenance.refresh_marks([chi_mark(kase, provenance, incoming_dir)], incoming_dir)
      return unless kase.mark == "legacy"

      raw = JSON.parse(File.read(path))
      raw["files"].fetch(kase.key)["legacy_base"] = true
      File.write(path, JSON.pretty_generate(raw))
    end

    # The mark's words as chi writes them (Installer#note_conflict): why no
    # merge, what the bundle's text it speaks of changed, from the base, the
    # file and that text. A mark chi can't word (no file) says only behind.
    def chi_mark(kase, provenance, incoming_dir)
      view = Samagotchi::MemoryBundle::Merger::Upgrade.new(provenance: provenance, target_dir: BundleStateCorpus.memories_dir,
                                                           source_dir: incoming_dir)
      outcome = view.outcome(kase.key)
      view.behind(kase.key, outcome.conflict? ? outcome : Samagotchi::MemoryBundle::Merger::CONFLICT, "1.0.0")
    rescue SystemCallError
      Samagotchi::MemoryBundle::FileStanding::Behind.new(file: kase.key, version: "1.0.0")
    end

    def scratch_file(name, text)
      path = File.join(@root, "scratch", name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
      path
    end
  end

  # The 0.149 record shape, from the 0.155 one (git diff v0.149.0 v0.155.0 --
  # provenance.rb installed_bundle.rb): a mark is conflict: true alone; no
  # manifest_sha or installed_by; no kept manifest.yml; no incoming/ texts.
  module Shapes
    module_function

    def v149!(bundles_dir)
      Dir.glob(File.join(bundles_dir, "*", "manifest.json")).each do |path|
        raw = JSON.parse(File.read(path))
        raw.delete("manifest_sha")
        raw.delete("installed_by")
        raw.fetch("files", {}).each_value do |entry|
          next unless entry["conflict"]

          entry.keep_if { |field, _| %w[checksum conflict description].include?(field) }
        end
        File.write(path, JSON.pretty_generate(raw))
        FileUtils.rm_f(File.join(File.dirname(path), "manifest.yml"))
        FileUtils.rm_rf(File.join(File.dirname(path), "incoming"))
      end
    end
  end
end

require_relative "observe"
require_relative "goldens"

module BundleStateCorpus
  # What a corpus spec file's examples call (one example per case, every
  # column, both shapes); the file keeps @sandbox (before(:all)) and its Goldens.
  module Examples
    def expect_memory_cells(goldens, kase)
      skip "root reads a mode 000 file" if kase.unreadable && Process.uid.zero?
      allow(Samagotchi::MemoryBundle::ShippedHistory).to receive(:shipped?).and_return(kase.shipped_history)
      columns = MEMORY_GROUPS.fetch(goldens.name)
      stub_const("Samagotchi::MemoryBundle::SystemBundle::GEM_BUNDLE_DIR", @sandbox.same_source(kase)) if columns.include?("restore")
      shapes = MARKED_ONLY_149.include?(goldens.name) && !kase.marked? ? SHAPES.first(1) : SHAPES
      expect_cells(goldens, kase, Observer.new(@sandbox, kase), columns, shapes)
    end

    def expect_cells(goldens, kase, observer, columns, shapes = SHAPES)
      goldens.record(kase.id, columns.to_h { |column| [column, shapes.to_h { |shape| [shape, observer.cell(shape, column)] }] })
      return if Goldens.update?

      problems = goldens.mismatches(kase.id)
      expect(problems).to be_empty, "#{problems.join("\n")}\n#{goldens.hint}"
    end
  end
end
