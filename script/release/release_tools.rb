# frozen_string_literal: true

require "digest"
require "open3"
require "yaml"

# The logic behind the Rakefile's `bundles:` and `release:` tasks, kept out of
# lib/ (it isn't shipped) and free of Rake so the specs can call it. Every
# method takes the repository root, so a spec can point it at a temp copy.
# See docs/releasing.md for how the tasks fit together.
module ReleaseTools
  REPO_URL = "https://github.com/dm1try/samagotchi"
  BUNDLES_DIR = "lib/samagotchi/bundles"
  VERSION_FILE = "lib/samagotchi/version.rb"
  SYSTEM_MANIFEST = "#{BUNDLES_DIR}/system/manifest.yml".freeze
  CHANGELOG = "CHANGELOG.md"
  VERSION_PATTERN = /\A\d+\.\d+\.\d+(?:\.[0-9A-Za-z.]+)?\z/

  class Error < StandardError; end

  module_function

  # --- versions ---------------------------------------------------------

  def gem_version(root)
    File.read(File.join(root, VERSION_FILE))[/VERSION = "([^"]+)"/, 1] or raise Error, "no VERSION in #{VERSION_FILE}"
  end

  def system_bundle_version(root)
    YAML.safe_load_file(File.join(root, SYSTEM_MANIFEST))["version"].to_s
  end

  # --- bundle manifests' sha256 lines -------------------------------------

  def bundle_dirs(root)
    Dir.glob(File.join(root, BUNDLES_DIR, "*", "manifest.yml")).map { |m| File.dirname(m) }.sort
  end

  # The manifest text with every sha256 line recomputed from the file it
  # names, the layout otherwise untouched. The three shapes:
  #   files:            a.md: sha256:<hex>             (dir/a.md)
  #   hooks:            h.rb:\n    sha256: sha256:<hex> (dir/hooks/h.rb)
  #   plugin:           file: p.rb\n  sha256: sha256:<hex> (dir/p.rb)
  #   scripts:          s.rb: sha256:<hex>             (dir/scripts/s.rb)
  # Returns [text, [[relative file, old sha, new sha], ...]] for the lines
  # that changed. A named file that's missing raises.
  def refresh_manifest(text, dir)
    plugin_file = (YAML.safe_load(text) || {}).dig("plugin", "file")
    top = sub = nil
    changes = []
    lines = text.lines.map do |line|
      if line.match?(/\A[^\s#]/)
        top = line[/\A([^\s#][^:]*):/, 1]
        sub = nil
      end
      sub = line[/\A  ([^\s#][^:]*):/, 1] if line.match?(/\A  [^\s#]/)
      file, prefix = sha_line(line, top, sub, plugin_file)
      next line unless file

      path = File.join(dir, file)
      raise Error, "#{File.basename(dir)}/manifest.yml names #{file}, which isn't there" unless File.file?(path)

      old = line[/sha256:(\h*)\s*\z/, 1]
      new = Digest::SHA256.hexdigest(File.binread(path))
      changes << [file, old, new] unless old == new
      "#{prefix}sha256:#{new}#{"\n" if line.end_with?("\n")}"
    end
    [lines.join, changes]
  end

  # [file relative to the bundle dir, the line up to its sha256: value] for a
  # sha line, nil for any other line.
  def sha_line(line, top, sub, plugin_file)
    case top
    when "files"
      m = line.match(/\A(  ["']?([^"':]+)["']?: )sha256:\h*\s*\z/) and [m[2], m[1]]
    when "hooks"
      m = line.match(/\A(    sha256: )sha256:\h*\s*\z/) and sub and [File.join("hooks", sub.delete("\"'")), m[1]]
    when "plugin"
      m = line.match(/\A(  sha256: )sha256:\h*\s*\z/) and plugin_file and [plugin_file, m[1]]
    when "scripts"
      m = line.match(/\A(  ["']?([^"':]+)["']?: )sha256:\h*\s*\z/) and [File.join("scripts", m[2]), m[1]]
    end
  end

  # Rewrites every bundle manifest whose sha lines are stale. Returns
  # {"bundle/manifest.yml" => changes}.
  def refresh_bundle_shas!(root)
    bundle_dirs(root).each_with_object({}) do |dir, out|
      manifest = File.join(dir, "manifest.yml")
      text, changes = refresh_manifest(File.read(manifest), dir)
      next if changes.empty?

      File.write(manifest, text)
      out["#{File.basename(dir)}/manifest.yml"] = changes
    end
  end

  def stale_shas(root)
    bundle_dirs(root).flat_map do |dir|
      _, changes = refresh_manifest(File.read(File.join(dir, "manifest.yml")), dir)
      changes.map { |file, _old, _new| "#{File.basename(dir)}: stale sha256 for #{file} (rake bundles:sha)" }
    end
  end

  # --- git --------------------------------------------------------------

  def git(root, *)
    out, status = Open3.capture2e("git", "-C", root, *)
    [out, status.success?]
  end

  def last_tag(root)
    out, ok = git(root, "describe", "--tags", "--abbrev=0", "--match", "v*")
    ok ? out.strip : nil
  end

  # A bundle whose directory differs from the tag (commits or uncommitted
  # edits to tracked files) must carry a higher version: only the system
  # bundle upgrades by itself; users upgrade the others with `chi bundle
  # upgrade`, which compares versions. A bundle new since the tag is fine.
  def unbumped_bundles(root, tag)
    bundle_dirs(root).filter_map do |dir|
      rel = dir.delete_prefix("#{File.expand_path(root)}/")
      _, same = git(root, "diff", "--quiet", tag, "--", rel)
      next if same

      old_text, existed = git(root, "show", "#{tag}:#{rel}/manifest.yml")
      next unless existed

      old = YAML.safe_load(old_text)["version"].to_s
      new = YAML.safe_load_file(File.join(dir, "manifest.yml"))["version"].to_s
      next if Gem::Version.new(new) > Gem::Version.new(old)

      "#{File.basename(dir)}: changed since #{tag} but still version #{new} (bump its manifest version)"
    end
  end

  # A bundle changed since the tag whose requires_chi the tagged chi already
  # meets: if the change uses anything new in chi, that chi would install it
  # and break (guardrails 0.2.0 and `models:` under 0.8.0). A warning only:
  # most bundle changes need nothing new.
  def stale_requires_chi(root, tag)
    tagged = Gem::Version.new(tag.delete_prefix("v"))
    bundle_dirs(root).filter_map do |dir|
      requires = YAML.safe_load_file(File.join(dir, "manifest.yml"))["requires_chi"] or next
      next unless Gem::Requirement.new(*requires.to_s.split(",").map(&:strip)).satisfied_by?(tagged)

      _, same = git(root, "diff", "--quiet", tag, "--", dir.delete_prefix("#{File.expand_path(root)}/"))
      next if same

      "#{File.basename(dir)}: changed since #{tag} and requires_chi #{requires.to_s.inspect} admits that chi: " \
        "raise it if the change uses anything newer"
    end
  end

  # [problems, notes] for `rake bundles:check`.
  def bundles_check(root)
    problems = stale_shas(root)
    notes = []
    if (tag = last_tag(root))
      problems += unbumped_bundles(root, tag)
      notes += stale_requires_chi(root, tag)
    else
      notes << "No v* tag yet: skipped the changed-bundle version check."
    end
    [problems, notes]
  end

  # --- CHANGELOG ----------------------------------------------------------

  HEADING = /^## \[([^\]]+)\][^\n]*\n/
  LINK_REF = /^\[[^\]]+\]: \S+\s*$/

  # The body of `## [version]` (without its heading), stripped; nil when
  # there's no such section.
  def changelog_section(text, version)
    start = text.match(/^## \[#{Regexp.escape(version)}\][^\n]*\n/) or return nil
    rest = text[start.end(0)..]
    stop = [rest =~ /^## \[/, rest =~ LINK_REF, rest.length].compact.min
    rest[0...stop].strip
  end

  def released_versions(text)
    text.scan(HEADING).flatten - ["Unreleased"]
  end

  # `## [Unreleased]` becomes `## [version] - date` under a fresh empty
  # Unreleased; the compare links at the bottom follow.
  def release_changelog(text, version, date, repo: REPO_URL)
    raise Error, "CHANGELOG.md has no ## [Unreleased] section" unless text.match?(/^## \[Unreleased\]/)
    raise Error, "CHANGELOG.md already has a ## [#{version}] section" if released_versions(text).include?(version)
    raise Error, "## [Unreleased] is empty: write the notes first (rake release:draft_changelog)" if changelog_section(text, "Unreleased").to_s.empty?

    previous = released_versions(text).first
    body = text.sub(/^## \[Unreleased\][^\n]*\n/, "## [Unreleased]\n\n## [#{version}] - #{date}\n")
    body = body.lines.reject { |l| l.start_with?("[Unreleased]: ") }.join.rstrip
    links = ["[Unreleased]: #{repo}/compare/v#{version}...HEAD",
             "[#{version}]: #{previous ? "#{repo}/compare/v#{previous}...v#{version}" : "#{repo}/releases/tag/v#{version}"}"]
    first_link = body.lines.index { |l| l.match?(LINK_REF) }
    if first_link
      lines = body.lines
      (lines[0...first_link].join.rstrip + "\n\n" + links.join("\n") + "\n" + lines[first_link..].join).rstrip + "\n"
    else
      "#{body}\n\n#{links.join("\n")}\n"
    end
  end

  # --- bump ---------------------------------------------------------------

  # VERSION, the system manifest's version, Gemfile.lock's samagotchi lines
  # and the CHANGELOG. requires_chi lines are never touched: a bundle that
  # needs the new chi says so in its own change. No commit.
  def bump!(root, version, date: Time.now.strftime("%Y-%m-%d"))
    raise Error, "#{version.inspect} isn't a version (x.y.z)" unless version.match?(VERSION_PATTERN)

    current = gem_version(root)
    raise Error, "#{version} isn't above the current #{current}" unless Gem::Version.new(version) > Gem::Version.new(current)

    changelog = File.join(root, CHANGELOG)
    new_changelog = release_changelog(File.read(changelog), version, date)

    edit(root, VERSION_FILE) { |t| t.sub(/VERSION = "[^"]+"/, %(VERSION = "#{version}")) }
    edit(root, SYSTEM_MANIFEST) { |t| t.sub(/^version: .*$/, "version: #{version}") }
    edit(root, "Gemfile.lock") { |t| t.gsub(/^(\s+)samagotchi \(#{Regexp.escape(current)}\)$/, "\\1samagotchi (#{version})") }
    File.write(changelog, new_changelog)
    current
  end

  def edit(root, rel)
    path = File.join(root, rel)
    text = File.read(path)
    new = yield text
    raise Error, "#{rel}: nothing to change" if new == text

    File.write(path, new)
  end

  # --- draft changelog ----------------------------------------------------

  SKIP = /\A(Merge |fixup! |squash! |amend! |Revert "|WIP\b)|\A(System bundle and gem|Bump|Version) [\d.]+\z/i
  FIXED = /\b(fix(es|ed)?|bug|crash(es|ed)?|regression|broken|no longer|instead of|wrong|(it|they) (said|was|were|showed))\b|n't\b.*\(|\bstale\b/i
  ADDED = /\A(add(s|ed)?|new|introduce|support)\b|\bnew (command|flag|setting|tool|bundle|option)\b/i

  def classify(subject)
    return nil if subject.match?(SKIP)
    return "Fixed" if subject.match?(FIXED)
    return "Added" if subject.match?(ADDED)

    "Changed"
  end

  # A draft `## [Unreleased]` from commit subjects, grouped; the agent edits
  # it into user-facing lines before the user approves it.
  def draft_changelog(subjects)
    groups = { "Added" => [], "Changed" => [], "Fixed" => [] }
    subjects.each { |s| (g = classify(s.strip)) and groups[g] << s.strip }
    out = +"## [Unreleased]\n"
    groups.each do |name, items|
      next if items.empty?

      out << "\n### #{name}\n\n" << items.map { |s| "- #{s}\n" }.join
    end
    out
  end

  def subjects_since(root, tag)
    range = tag ? "#{tag}..HEAD" : "HEAD"
    out, ok = git(root, "log", "--no-merges", "--reverse", "--format=%s", range)
    raise Error, "git log failed: #{out}" unless ok

    out.lines.map(&:chomp).reject(&:empty?)
  end

  # --- release:check pieces ---------------------------------------------

  def dirty_tracked_files(root)
    out, ok = git(root, "status", "--porcelain", "--untracked-files=no")
    raise Error, "git status failed: #{out}" unless ok

    out.lines.map(&:chomp)
  end

  # The checks that need no build: [problems].
  def consistency_problems(root)
    version = gem_version(root)
    problems = []
    dirty = dirty_tracked_files(root)
    problems << "uncommitted changes to tracked files:\n  #{dirty.join("\n  ")}" unless dirty.empty?
    system = system_bundle_version(root)
    problems << "VERSION #{version} != system bundle #{system}" unless system == version
    changelog = File.join(root, CHANGELOG)
    section = File.exist?(changelog) ? changelog_section(File.read(changelog), version) : nil
    problems << "CHANGELOG.md has no (or an empty) ## [#{version}] section" if section.to_s.empty?
    problems
  end
end
