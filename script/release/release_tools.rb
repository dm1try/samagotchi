# frozen_string_literal: true

require "open3"
require "yaml"
require_relative "../../lib/samagotchi/memory_bundle/shas"

# The logic behind the Rakefile's `bundles:` and `release:` tasks, kept out of
# lib/ (it isn't shipped) and free of Rake so the specs can call it. Every
# method takes the repository root, so a spec can point it at a temp copy.
# See docs/releasing.md for how the tasks fit together.
module ReleaseTools
  REPO_URL = "https://github.com/dm1try/samagotchi"
  BUNDLES_DIR = "lib/samagotchi/bundles"
  VERSION_FILE = "lib/samagotchi/version.rb"
  SYSTEM_BUNDLE = "system"
  SYSTEM_MANIFEST = "#{BUNDLES_DIR}/#{SYSTEM_BUNDLE}/manifest.yml".freeze
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

  # The manifest text with its sha256 lines recomputed, and the lines that
  # changed (MemoryBundle::Shas.refresh, which raises Shas::Error).
  def refresh_manifest(text, dir) = Samagotchi::MemoryBundle::Shas.refresh(dir, text)

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
      Samagotchi::MemoryBundle::Shas.stale(dir).map do |stale|
        next "#{File.basename(dir)}: no sha256 line for #{stale.file} (add one, then rake bundles:sha)" if stale.old.nil?

        "#{File.basename(dir)}: stale sha256 for #{stale.file} (rake bundles:sha)"
      end
    end
  end

  # A shipped bundle's top-level *.md that its files: doesn't list: an
  # install takes only the listed ones (MemoryBundle::MemoryFiles), and a
  # listed file gets its sha line (rake bundles:sha).
  def unlisted_memories(root)
    bundle_dirs(root).flat_map do |dir|
      parsed = YAML.safe_load_file(File.join(dir, "manifest.yml")) || {}
      listed = parsed["files"].is_a?(Hash) ? parsed["files"].keys.map(&:to_s) : []
      (Dir.glob(File.join(dir, "*.md")).map { |f| File.basename(f) }.sort - listed).map do |file|
        "#{File.basename(dir)}: ships #{file}, which files: doesn't list (an install leaves it out; add it, then rake bundles:sha)"
      end
    end
  end

  # --- git --------------------------------------------------------------

  # The pathspecs of what a bundle ships: its folder without its spec/
  # (the bundle's own specs, never installed: a change there needs no
  # version bump).
  def shipped_paths(rel) = [rel, ":(exclude)#{rel}/spec"]

  def git(root, *)
    out, status = Open3.capture2e("git", "-C", root, *)
    [out, status.success?]
  end

  # The newest v* tag reachable from HEAD; a tag on HEAD itself only when
  # tracked files have changed since. In the release workflow HEAD is the
  # tag being released, with a clean tree: comparing a bundle with it would
  # find nothing changed, so the one before it counts. Before the tag is cut
  # (release:check) that is simply the newest tag; edits on top of a tagged
  # HEAD compare with that tag.
  def last_tag(root)
    _, clean = git(root, "diff", "--quiet", "HEAD")
    on_head = clean ? git(root, "tag", "--points-at", "HEAD", "--list", "v*").first : ""
    excludes = on_head.split.flat_map { |tag| ["--exclude", tag] }
    out, ok = git(root, "describe", "--tags", "--abbrev=0", "--match", "v*", *excludes, "HEAD")
    ok ? out.strip : nil
  end

  # A bundle whose directory differs from the tag (commits or uncommitted
  # edits to tracked files) must carry a higher version: only the system
  # bundle upgrades by itself; users upgrade the others with `chi bundle
  # upgrade`, which compares versions. A bundle new since the tag is fine.
  # +skip+: bundle names left out (CI mode leaves out the system bundle).
  def unbumped_bundles(root, tag, skip: [])
    bundle_dirs(root).filter_map do |dir|
      next if skip.include?(File.basename(dir))

      rel = dir.delete_prefix("#{File.expand_path(root)}/")
      _, same = git(root, "diff", "--quiet", tag, "--", *shipped_paths(rel))
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
  # most bundle changes need nothing new (one that does is marked
  # requires_chi_next, and bundles_check drops its warning). A meta bundle (a profile, its
  # includes:) is left out: installing it checks each member's own
  # requires_chi (Profile.install_member), so its floor guards nothing
  # here (low_meta_floors keeps it at its members' highest).
  def stale_requires_chi(root, tag)
    tagged = Gem::Version.new(tag.delete_prefix("v"))
    bundle_dirs(root).filter_map do |dir|
      manifest = YAML.safe_load_file(File.join(dir, "manifest.yml"))
      next if manifest["includes"]

      requires = manifest["requires_chi"] or next
      next unless Gem::Requirement.new(*requires.to_s.split(",").map(&:strip)).satisfied_by?(tagged)

      _, same = git(root, "diff", "--quiet", tag, "--", *shipped_paths(dir.delete_prefix("#{File.expand_path(root)}/")))
      next if same

      "#{File.basename(dir)}: changed since #{tag} and requires_chi #{requires.to_s.inspect} admits that chi: " \
        "mark it requires_chi_next if the change uses anything newer"
    end
  end

  # A meta bundle (a profile, its includes:) whose requires_chi is below a
  # member's: [notes]. Nothing breaks (installing it checks each member's
  # own requires_chi, Profile.install_member), but the profile then claims
  # a chi its members don't run on. A note, not a failure: release:bump
  # raises such a profile with its members (raised_profile_floors), and
  # release:check, right after it, runs bundles:check in full.
  def low_meta_floors(root)
    low_profiles(root).map do |low|
      have = low.requires ? low.requires.to_s.inspect : "(none)"
      "#{low.name}: requires_chi #{have} is below member #{low.member}'s #{low.member_requires.inspect}: " \
        "raise it to \">= #{low.floor}\" (and bump #{low.name}'s version)"
    end
  end

  # A profile below its highest member: its manifest path, name and
  # requires_chi (nil for none), that member, its requires_chi and floor.
  LowProfile = Data.define(:path, :name, :requires, :member, :member_requires, :floor)

  # The profiles whose requires_chi is below a member's, as [LowProfile].
  # +texts+: {manifest path => text} read in place of the file (release:bump's
  # manifests before it writes them).
  def low_profiles(root, texts = {})
    read = ->(path) { YAML.safe_load(texts.fetch(path) { File.read(path) }) || {} }
    bundle_dirs(root).filter_map do |dir|
      path = File.join(dir, "manifest.yml")
      manifest = read.call(path)
      members = manifest["includes"] or next

      member, requires, floor = Array(members).filter_map do |name|
        member_path = File.join(root, BUNDLES_DIR, name.to_s, "manifest.yml")
        next unless File.file?(member_path)

        member_requires = read.call(member_path)["requires_chi"]
        member_floor = requires_floor(member_requires)
        [name.to_s, member_requires.to_s, member_floor] if member_floor
      end.max_by(&:last)
      own = requires_floor(manifest["requires_chi"])
      next unless floor && (own.nil? || own < floor)

      LowProfile.new(path: path, name: File.basename(dir), requires: manifest["requires_chi"],
                     member: member, member_requires: requires, floor: floor)
    end
  end

  # The lowest chi a requires_chi admits: its highest >=, >, ~> or = bound;
  # nil for none.
  def requires_floor(requires)
    return nil if requires.to_s.strip.empty?

    Gem::Requirement.new(*requires.to_s.split(",").map(&:strip)).requirements
                    .filter_map { |op, version| version if %w[>= > ~> =].include?(op) }.max
  end

  # --- requires_chi_next: a floor raised at release time -------------------

  # A bundle that needs something new in chi says so with
  # `requires_chi_next: true` (or a short reason) in its manifest instead of
  # raising requires_chi to a chi that isn't released yet (main would then
  # refuse its own bundle). `release:bump` turns the marker into
  # `requires_chi: ">= <released version>"`; `release:check` fails while one
  # is left. chi itself ignores the key.
  NEXT_KEY = "requires_chi_next"
  NEXT_LINE = /^#{NEXT_KEY}:[^\n]*\n?/
  REQUIRES_LINE = /^requires_chi:[^\n]*$/

  # {bundle dir => the marker's value} for every manifest that carries one.
  def requires_chi_next(root)
    bundle_dirs(root).each_with_object({}) do |dir, out|
      value = YAML.safe_load_file(File.join(dir, "manifest.yml"))&.fetch(NEXT_KEY, nil)
      out[dir] = value unless value.nil? || value == false
    end
  end

  # A marker that isn't `true` or a one-line reason, or that release:bump
  # couldn't rewrite (a multi-line value): [problems].
  def requires_chi_next_problems(root)
    requires_chi_next(root).filter_map do |dir, value|
      lines = File.read(File.join(dir, "manifest.yml")).scan(NEXT_LINE)
      shape_ok = value == true || (value.is_a?(String) && !value.strip.empty?)
      # One line that alone parses to the same value: not a block scalar
      # or a value continued on the next lines, which the rewrite would cut.
      next if shape_ok && lines.size == 1 && (YAML.safe_load(lines.first) || {})[NEXT_KEY] == value

      "#{File.basename(dir)}: #{NEXT_KEY}: must be `true` or a one-line reason, on its own top-level line"
    end
  end

  # The manifest text with requires_chi raised to ">= version" (replacing
  # the line, or added after `version:`) and the marker line dropped.
  def raise_requires_chi(text, version)
    line = %(requires_chi: ">= #{version}")
    text = text.sub(NEXT_LINE, "")
    return text.sub(REQUIRES_LINE, line) if text.match?(REQUIRES_LINE)

    text.sub(/^version:[^\n]*\n/) { |v| "#{v}#{line}\n" }
  end

  # The marked bundles' new manifest texts, {path => text}; raises (and so
  # changes nothing) on a marker it can't rewrite.
  def raised_requires_chi(root, version)
    problems = requires_chi_next_problems(root)
    raise Error, problems.join("; ") unless problems.empty?

    requires_chi_next(root).keys.to_h do |dir|
      path = File.join(dir, "manifest.yml")
      [path, raise_requires_chi(File.read(path), version)]
    end
  end

  # A profile raised with its members: its name, version before and after
  # (a patch bump) and its new requires_chi floor.
  RaisedProfile = Data.define(:name, :old_version, :version, :floor)

  # The profiles left below a member once +texts+ ({path => text}, the
  # members' raised manifests) are written: {path => text} with each one's
  # requires_chi raised to that member's floor and its version patch-bumped,
  # and the [RaisedProfile]s. A profile whose version already moved since
  # +tag+ (a member joined it this release), or that is new since it, keeps
  # its version: one release, one bump.
  def raised_profile_floors(root, texts, tag: last_tag(root))
    lows = low_profiles(root, texts)
    out = lows.to_h do |low|
      text = raise_requires_chi(texts.fetch(low.path) { File.read(low.path) }, low.floor)
      [low.path, bumped_since?(root, tag, low.path, text) ? text : patch_bump(text, low.name)]
    end
    profiles = lows.map do |low|
      RaisedProfile.new(name: low.name, old_version: manifest_version(texts.fetch(low.path) { File.read(low.path) }),
                        version: manifest_version(out[low.path]), floor: low.floor.to_s)
    end
    [out, profiles]
  end

  def manifest_version(text) = (YAML.safe_load(text) || {})["version"].to_s

  # Whether the manifest at +path+ (now +text+) is new since +tag+ or has a
  # higher version than at it; false without a tag.
  def bumped_since?(root, tag, path, text)
    return false unless tag

    rel = File.expand_path(path).delete_prefix("#{File.expand_path(root)}/")
    old_text, existed = git(root, "show", "#{tag}:#{rel}")
    return true unless existed

    Gem::Version.new(manifest_version(text)) > Gem::Version.new(manifest_version(old_text))
  end

  # The manifest text with its version's patch number raised (0.7.1 → 0.7.2).
  def patch_bump(text, name)
    old = manifest_version(text)
    raise Error, "#{name}: version #{old.inspect} isn't x.y.z" unless old.match?(/\A\d+\.\d+\.\d+\z/)

    major, minor, patch = old.split(".").map(&:to_i)
    text.sub(/^version:[^\n]*$/, "version: #{major}.#{minor}.#{patch + 1}")
  end

  # [problems, notes] for `rake bundles:check`. +ci+ (`rake
  # bundles:check[ci]`, the CI workflow): the changed-bundle version check
  # leaves out the system bundle, whose version moves only with VERSION at
  # `rake release:bump`, so it is changed and unbumped between releases.
  # The sha lines stay strict for every bundle.
  def bundles_check(root, ci: false)
    problems = stale_shas(root) + unlisted_memories(root) + requires_chi_next_problems(root)
    notes = low_meta_floors(root)
    marked = requires_chi_next(root).keys.map { |dir| File.basename(dir) }
    if (tag = last_tag(root))
      problems += unbumped_bundles(root, tag, skip: ci ? [SYSTEM_BUNDLE] : [])
      notes += stale_requires_chi(root, tag).reject { |n| marked.include?(n[/\A[^:]+/]) }
    else
      notes << "No v* tag yet: skipped the changed-bundle version check."
    end
    notes += marked.map { |name| "#{name}: #{NEXT_KEY} is set: rake release:bump raises its requires_chi" }
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

  # What bump! changed: the version before, the bundles whose
  # requires_chi_next it turned into requires_chi, and the [RaisedProfile]s.
  Bumped = Data.define(:old, :raised, :profiles)

  # VERSION, the system manifest's version, Gemfile.lock's samagotchi lines,
  # the CHANGELOG, the requires_chi of every bundle marked requires_chi_next
  # (raised to ">= version", the marker dropped), and then every profile
  # below a member's requires_chi (raised to it, with a patch bump of the
  # profile's version unless it moved since the last tag). No other
  # requires_chi is touched. No commit; a Bumped.
  def bump!(root, version, date: Time.now.strftime("%Y-%m-%d"))
    raise Error, "#{version.inspect} isn't a version (x.y.z)" unless version.match?(VERSION_PATTERN)

    current = gem_version(root)
    raise Error, "#{version} isn't above the current #{current}" unless Gem::Version.new(version) > Gem::Version.new(current)

    changelog = File.join(root, CHANGELOG)
    new_changelog = release_changelog(File.read(changelog), version, date)
    raised = raised_requires_chi(root, version)
    profile_texts, profiles = raised_profile_floors(root, raised)

    edit(root, VERSION_FILE) { |t| t.sub(/VERSION = "[^"]+"/, %(VERSION = "#{version}")) }
    edit(root, SYSTEM_MANIFEST) { |t| t.sub(/^version: .*$/, "version: #{version}") }
    edit(root, "Gemfile.lock") { |t| t.gsub(/^(\s+)samagotchi \(#{Regexp.escape(current)}\)$/, "\\1samagotchi (#{version})") }
    File.write(changelog, new_changelog)
    raised.merge(profile_texts).each { |path, text| File.write(path, text) }
    Bumped.new(old: current, raised: raised.keys.map { |path| File.basename(File.dirname(path)) }, profiles: profiles)
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
    requires_chi_next(root).each_key do |dir|
      problems << "#{File.basename(dir)}: #{NEXT_KEY} is still set: raise its requires_chi to \">= #{version}\" " \
                  "and drop the marker (rake release:bump does both)"
    end
    problems << remote_not_yet_problem if remote_not_yet?(root)
    problems
  end

  # The remote attach's temporary refusals (TerminalUI::RemoteLink::NOT_YET:
  # /exit, /archive, /stats, /recap through a remote) ship only with their
  # routes (remote-sessions P4-D8: P4a and P4b in one release).
  REMOTE_LINK = "lib/samagotchi/terminal_ui/remote_link.rb"

  def remote_not_yet?(root)
    path = File.join(root, REMOTE_LINK)
    File.exist?(path) && File.read(path).match?(/^\s*NOT_YET\s*=/)
  end

  def remote_not_yet_problem
    "#{REMOTE_LINK}: RemoteLink::NOT_YET is still defined: the remote attach's /exit, /archive, /stats and " \
      "/recap need their chi web routes (P4b) before a release"
  end
end
