# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "script/release/release_tools"

# bundler/gem_tasks provides build/install/install:local (into pkg/). Its
# `rake release` tags, pushes and publishes from this machine: removed below.
# Publishing happens only in GitHub Actions on a v* tag (docs/releasing.md).
require "bundler/gem_tasks"

%w[release release:guard_clean release:source_control_push release:rubygem_push].each do |name|
  Rake.application.instance_variable_get(:@tasks).delete(name)
end

desc "Not a local task: releases are published by GitHub Actions on a v* tag (docs/releasing.md)"
task :release do
  abort "No local release: run rake release:check, then tag v<VERSION> and push the tag (docs/releasing.md)."
end

ROOT = __dir__

namespace :gem do
  desc "Validate the gemspec"
  task :validate do
    spec = Gem::Specification.load("samagotchi.gemspec")
    result = spec.validate
    if result
      # validate returns true (ok) or array of warnings
      if result.is_a?(Array) && !result.empty?
        $stderr.puts "Gemspec validation warnings:"
        result.each { |msg| $stderr.puts "  - #{msg}" }
      end
    end
    puts "✓ Gemspec is valid"
  end

  desc "Clean built .gem files from pkg/"
  task :clean => :clobber

  desc "Build the samagotchi gem into pkg/"
  task :build => "rake:build"

  desc "Build and install the samagotchi gem locally"
  task :install => [:validate, "rake:install:local"]
end

namespace :bundles do
  desc "Refresh the sha256 lines of the shipped bundles' manifests"
  task :sha do
    changed = ReleaseTools.refresh_bundle_shas!(ROOT)
    if changed.empty?
      puts "All bundle sha256 lines are current."
    else
      changed.each do |manifest, changes|
        changes.each { |file, _old, new| puts "#{manifest}: #{file} → sha256:#{new[0, 12]}…" }
      end
      puts "Changed a bundle's content? Bump its manifest version too."
    end
  end

  desc "Check the bundle manifests: sha256 lines match; a bundle changed since the last v* tag has a higher version"
  task :check do
    problems, notes = ReleaseTools.bundles_check(ROOT)
    notes.each { |n| puts "note: #{n}" }
    abort "bundles:check failed:\n  #{problems.join("\n  ")}" unless problems.empty?
    puts "bundles:check OK (#{ReleaseTools.bundle_dirs(ROOT).size} bundles)"
  end
end

namespace :release do
  desc "Bump VERSION, the system bundle, Gemfile.lock and the CHANGELOG (Unreleased → [VERSION] - today); no commit"
  task :bump, [:version] do |_t, args|
    version = args[:version] or abort "usage: rake 'release:bump[0.2.0]'"
    old = ReleaseTools.bump!(ROOT, version)
    puts "Bumped #{old} → #{version}: #{ReleaseTools::VERSION_FILE}, #{ReleaseTools::SYSTEM_MANIFEST}, Gemfile.lock, CHANGELOG.md"
    puts "Review with `git diff`, then run rake release:check and commit."
  rescue ReleaseTools::Error => e
    abort "release:bump: #{e.message}"
  end

  desc "Print the CHANGELOG section of VERSION (default: the current VERSION)"
  task :notes, [:version] do |_t, args|
    version = args[:version] || ReleaseTools.gem_version(ROOT)
    section = ReleaseTools.changelog_section(File.read(File.join(ROOT, ReleaseTools::CHANGELOG)), version)
    abort "CHANGELOG.md has no ## [#{version}] section" if section.to_s.empty?
    puts section
  end

  desc "Print a draft Unreleased section from the commit subjects since the last v* tag"
  task :draft_changelog do
    tag = ReleaseTools.last_tag(ROOT)
    warn(tag ? "Commits since #{tag}:" : "No v* tag yet: every commit since the root.")
    puts ReleaseTools.draft_changelog(ReleaseTools.subjects_since(ROOT, tag))
  end

  desc "Everything a release needs: clean tree, versions, CHANGELOG, bundles, suites, gem build, a clean install that runs"
  task :check do
    version = ReleaseTools.gem_version(ROOT)
    step = ->(name) { puts "\n== #{name}" }

    step.call("tree, versions, CHANGELOG (#{version})")
    problems = ReleaseTools.consistency_problems(ROOT)
    abort "release:check failed:\n  #{problems.join("\n  ")}" unless problems.empty?
    puts "OK"

    step.call("bundles")
    Rake::Task["bundles:check"].invoke

    step.call("specs")
    sh "bundle exec rspec --format progress"
    sh "npm test"

    step.call("gem build")
    FileUtils.mkdir_p(File.join(ROOT, "pkg"))
    gem_file = File.join(ROOT, "pkg", "samagotchi-#{version}.gem")
    sh "gem", "build", File.join(ROOT, "samagotchi.gemspec"), "--output", gem_file

    step.call("install into a clean GEM_HOME and run chi")
    Dir.mktmpdir("samagotchi-release-check-") do |tmp|
      gem_home = File.join(tmp, "gems")
      home = File.join(tmp, "home")
      FileUtils.mkdir_p(home)
      env = {
        "GEM_HOME" => gem_home, "GEM_PATH" => gem_home, "HOME" => home,
        "XDG_CONFIG_HOME" => File.join(home, ".config"), "XDG_STATE_HOME" => File.join(home, ".local/state"),
        "XDG_DATA_HOME" => File.join(home, ".local/share"), "XDG_CACHE_HOME" => File.join(home, ".cache"),
        "SAMAGOTCHI_DEFAULT_MODEL" => nil, "SAMAGOTCHI_LOG_DISABLE" => "true"
      }
      chi = File.join(gem_home, "bin", "chi")
      Bundler.with_unbundled_env do
        sh env, "gem", "install", gem_file, "--no-document", "--install-dir", gem_home
        out = IO.popen(env, [chi, "--version"], &:read)
        puts out
        abort "chi --version printed #{out.inspect}, not \"chi #{version}\"" unless out.strip == "chi #{version}"
        sh env, chi, "self"
        sh env, chi, "bundle", "list"
      end
    end
    puts "\nrelease:check OK: samagotchi #{version} (#{gem_file.delete_prefix("#{ROOT}/")})"
  end
end
