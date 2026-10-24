# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "script/release/release_tools"
require_relative "script/deps/deps_check"

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
    # validate returns true (ok) or array of warnings
    if result && result.is_a?(Array) && !result.empty?
      $stderr.puts "Gemspec validation warnings:"
      result.each { |msg| $stderr.puts "  - #{msg}" }
    end
    puts "✓ Gemspec is valid"
  end

  desc "Clean built .gem files from pkg/"
  task clean: :clobber

  desc "Build the samagotchi gem into pkg/"
  task build: "rake:build"

  desc "Build and install the samagotchi gem locally"
  task install: [:validate, "rake:install:local"]
end

desc "RuboCop over the repo: must report no offenses (CI runs it)"
task :lint do
  sh "bundle exec rubocop"
end

namespace :lint do
  desc "RuboCop's safe autocorrect (rubocop -a): what an offense usually needs"
  task :fix do
    sh "bundle exec rubocop -a"
  end
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

  desc "Check the bundle manifests: sha256 lines match; a bundle changed since the last v* tag has a higher version " \
       "(and a warning when its requires_chi admits that tag); a note for a profile whose requires_chi is below a " \
       "member's. bundles:check[ci], the CI workflow's: the version " \
       "check leaves out the system bundle (release:bump moves it with VERSION)"
  task :check, [:mode] do |_t, args|
    abort "usage: rake bundles:check or rake 'bundles:check[ci]'" unless [nil, "ci"].include?(args[:mode])

    problems, notes = ReleaseTools.bundles_check(ROOT, ci: args[:mode] == "ci")
    notes.each { |n| puts "note: #{n}" }
    abort "bundles:check failed:\n  #{problems.join("\n  ")}" unless problems.empty?
    puts "bundles:check OK (#{ReleaseTools.bundle_dirs(ROOT).size} bundles)"
  end

  desc "Run the shipped bundles' own specs (lib/samagotchi/bundles/*/spec) on the bundle test kit alone: no spec_helper, " \
       "as an external bundle's would run"
  task :specs do
    dirs = Dir[File.join(ROOT, "lib/samagotchi/bundles/*/spec")].sort
    abort "No bundle has a spec/ folder." if dirs.empty?

    # The failed examples, with their full descriptions, for CI's flake
    # check (script/rerun_failures.rb --log).
    FileUtils.mkdir_p(File.join(ROOT, "tmp"))
    sh "bundle", "exec", "rspec", "--options", File::NULL, "-r", "samagotchi/testing/rspec", "--format", "progress",
       "--format", "json", "--out", File.join(ROOT, "tmp/bundle_failures.json"), *dirs
  end
end

namespace :deps do
  desc "What our dependencies did since the last check: Splash/llama.cpp hosts in config.yml vs upstream, outdated " \
       "gems, outdated npm packages and npm audit; NEW marks changes (state: $XDG_STATE_HOME/samagotchi/deps-check.json, " \
       "DEPS_CHECK_STATE overrides). Informational, always exits 0. deps:check[json]: the same as JSON"
  task :check, [:format] do |_t, args|
    abort "usage: rake deps:check or rake 'deps:check[json]'" unless [nil, "json"].include?(args[:format])

    puts DepsCheck.check(ROOT, format: args[:format])
  end

  desc "Record the Splash version you read with `splash --version` (Splash's /status has none): " \
       "deps:splash_version[1.3.2] for every Splash host, deps:splash_version[host:port,1.3.2] for one"
  task :splash_version, [:first, :second] do |_t, args|
    address, version = args[:second] ? [args[:first], args[:second]] : [nil, args[:first]]
    abort "usage: rake 'deps:splash_version[1.3.2]' or rake 'deps:splash_version[host:port,1.3.2]'" unless version

    puts DepsCheck.record_splash_version(version, address: address)
  rescue DepsCheck::Error => e
    abort "deps:splash_version: #{e.message}"
  end
end

namespace :release do
  desc "Bump VERSION, the system bundle, Gemfile.lock and the CHANGELOG (Unreleased → [VERSION] - today), and raise " \
       "the requires_chi of bundles marked requires_chi_next, then of a profile left below a member's (with a patch " \
       "bump of its version); no commit"
  task :bump, [:version] do |_t, args|
    version = args[:version] or abort "usage: rake 'release:bump[0.2.0]'"
    bumped = ReleaseTools.bump!(ROOT, version)
    puts "Bumped #{bumped.old} → #{version}: #{ReleaseTools::VERSION_FILE}, #{ReleaseTools::SYSTEM_MANIFEST}, Gemfile.lock, CHANGELOG.md"
    unless bumped.raised.empty?
      puts "Raised requires_chi to \">= #{version}\" (requires_chi_next dropped): #{bumped.raised.join(", ")}"
    end
    bumped.profiles.each do |p|
      puts "Raised profile #{p.name}'s requires_chi to \">= #{p.floor}\" (its members'), #{p.old_version} → #{p.version}: " \
           "name it in the CHANGELOG's `chi update` line"
    end
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

    step.call("lint")
    Rake::Task["lint"].invoke
    sh "npm run lint"

    step.call("specs")
    # Both roots: plain rspec runs spec/ only (docs/testing.md).
    sh "bundle", "exec", "rspec", "--format", "progress", "spec", *Dir[File.join(ROOT, "lib/samagotchi/bundles/*/spec")].sort
    Rake::Task["bundles:specs"].invoke
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
