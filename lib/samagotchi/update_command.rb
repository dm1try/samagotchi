# frozen_string_literal: true

require_relative "config"
require_relative "desktop"
require_relative "gem_update"
require_relative "installed_gem"
require_relative "live_versions"
require_relative "memory_bundle/shipped_update"
require_relative "memory_bundle/system_bundle"
require_relative "session"
require_relative "version"

module Samagotchi
  # `chi update`: brings an installed chi up to date in one go: the system
  # bundle, the shipped bundles the user installed, and the macOS helper.
  # Unedited things update; edited ones are kept (.md) or replaced and
  # reported (hooks, plugin, rules, which didn't load once edited). Live
  # workers and a running chi web are reported, never restarted. Prints one
  # table; a second run changes nothing and says so.
  class UpdateCommand
    USAGE = <<~TEXT
      Usage: chi update [--dry-run] [--no-gem] [--no-bundles] [--no-desktop]
        Updates this chi's install: the gem (from rubygems.org), then the
        system bundle, the bundles chi ships that you installed (chi bundle
        list), and the desktop helper (macOS; rebuilt only when its sources
        changed). Edited memory files are kept and reported; nothing is
        installed that isn't already, and old gem versions stay.
        --dry-run      show what would change; change nothing
        --no-gem       don't install a newer gem (config update.gem: false)
        --no-bundles   leave the shipped bundles alone (config update.bundles: false)
        --no-desktop   leave the desktop helper alone (config update.desktop: false)
        Running sessions keep their chi until they idle out (30 min) or
        chi sessions stop ID; a running chi web needs a restart.
    TEXT

    FLAGS = { "--dry-run" => :dry_run, "--no-gem" => :no_gem, "--no-bundles" => :no_bundles, "--no-desktop" => :no_desktop,
              # Hidden: no pbs/lsregister/open/pkill for a helper under HOME=<tmp>.
              "--no-register" => :no_register }.freeze

    # A table row. info rows (live workers, chi web) say what runs; they
    # never fail.
    Row = Struct.new(:component, :from, :to, :status, :failed, keyword_init: true)

    # What a row says after a change, and in a dry run.
    VERBS = { update: ["updated", "would update"], install: ["installed", "would install"],
              restore: ["restored missing files", "would restore missing files"] }.freeze

    # @param gem_spec [Gem::Specification, nil] the installed gem (nil: a checkout)
    # @param platform [#call] register: → a Desktop::MacOS-like object
    # @param exec [#call] argv → replaces this process (the new chi's update)
    # @param bundler [Boolean] running under Bundler (bundle exec)
    def initialize(argv, stdout: $stdout, stderr: $stderr, gem_spec: InstalledGem.spec,
                   shipped_dir: MemoryBundle::SourceNormalizer::SHIPPED_DIR, platform: nil,
                   supported: Desktop.supported?, state_dir: Session.default_state_dir, web: nil,
                   gem_update: GemUpdate.new, exec: nil, bundler: nil)
      @gem_update = gem_update
      @exec = exec || ->(argv) { Kernel.exec(*argv) }
      @bundler = bundler.nil? ? (defined?(::Bundler) || !ENV["BUNDLE_GEMFILE"].to_s.empty?) : bundler
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @gem_spec = gem_spec
      @shipped_dir = shipped_dir
      @platform = platform || ->(register:) { Desktop::MacOS.new(register: register) }
      @supported = supported
      @state_dir = state_dir
      @web = web || [Config.get("web.host").to_s, Config.get("web.port").to_i]
    end

    # @return [Integer] 0 nothing failed, 1 a part failed (or a checkout), 2 usage
    def run
      options = parse or return 2
      if options[:help]
        @stdout.puts(USAGE)
        return 0
      end
      unless @gem_spec
        @stderr.puts("chi update: running from a checkout (#{InstalledGem::ROOT}): chi update updates an installed chi; " \
                     "git pull, or chi bundle upgrade NAME for one bundle")
        return 1
      end

      @dry_run = options[:dry_run]
      gem = gem_row(options)
      rows = [gem, system_bundle_row, *bundle_rows(options), desktop_row(options), *live_rows].compact
      print_table(rows)
      footers(options).each { |line| @stdout.puts(line) }
      @stdout.puts(summary(rows))
      rows.any?(&:failed) ? 1 : 0
    end

    private

    def parse
      argv = @argv.dup
      options = {}
      while (arg = argv.shift)
        if %w[-h --help help].include?(arg)
          options[:help] = true
        elsif arg == "--gem-from" && argv.first
          # Hidden: the old version, passed by the chi that installed this one.
          options[:gem_from] = argv.shift
        elsif FLAGS.key?(arg)
          options[FLAGS[arg]] = true
        else
          @stderr.puts("chi update: unknown option #{arg}")
          @stderr.puts(USAGE)
          return nil
        end
      end
      options
    end

    # Installs a newer gem and hands over to it (exec: the new code syncs
    # and prints the table), or says why not. A failed install is a failed
    # row; the sync then runs on this version.
    def gem_row(options)
      row = Row.new(component: "chi (gem)", from: VERSION)
      if options[:gem_from]
        row.from = options[:gem_from]
        row.to = VERSION
        return done(row, :update)
      end
      if (why = off(options, "gem"))
        return skipped(row, why)
      end
      return skipped(row, "under Bundler: bundle update samagotchi") if @bundler

      latest = begin
        @gem_update.latest
      rescue GemUpdate::Error => e
        return row.tap { |r| r.status = "couldn't check (#{e.message})" }
      end
      return up_to_date(row) unless @gem_update.newer?(latest)

      row.to = latest.version
      return done(row, :update) if @dry_run

      @stdout.puts("installing samagotchi #{latest.version}…")
      output, ok = @gem_update.install(latest)
      return failed(row, output.lines.map(&:strip).reject(&:empty?).last.to_s) unless ok

      hand_over(options, row)
    end

    # exec the wrapper, which activates the newest installed samagotchi.
    # Without one (installed with --bindir), this version syncs.
    def hand_over(options, row)
      wrapper = InstalledGem.wrapper(@gem_spec)
      return done(row, :update, "run chi update again to sync with it") unless wrapper

      passed = FLAGS.select { |_, key| options[key] && key != :dry_run }.keys
      @stdout.flush
      @exec.call([RbConfig.ruby, wrapper, "update", "--no-gem", "--gem-from", VERSION, *passed])
      done(row, :update) # only when exec is a spec's stand-in
    end

    # Why a part is off for this run, or nil.
    def off(options, part)
      return "--no-#{part}" if options[:"no_#{part}"]
      return "update.#{part}: false" unless Config.get("update.#{part}")

      nil
    end

    def system_bundle_row
      result = MemoryBundle::SystemBundle.sync(dry_run: @dry_run)
      row = Row.new(component: "system bundle", from: result.from, to: result.to)
      case result.status
      when :installed then done(row, :install)
      when :updated then done(row, :update, kept(result.kept, MemoryBundle::SystemBundle::BUNDLE_NAME))
      when :restored then done(row, :restore).tap { |r| r.to = nil }
      when :up_to_date then up_to_date(row)
      when :newer_installed then skipped(row, "newer than this chi's #{result.to}: left").tap { |r| r.to = nil }
      when :skipped then skipped(row, result.error)
      else failed(row, result.error)
      end
    end

    def bundle_rows(options)
      if (why = off(options, "bundles"))
        return [Row.new(component: "bundles", status: "skipped (#{why})")]
      end

      rows = MemoryBundle::ShippedUpdate.plan(shipped_dir: @shipped_dir)
      rows = MemoryBundle::ShippedUpdate.apply(rows) unless @dry_run
      rows.map { |r| bundle_row(r) }
    end

    def bundle_row(update)
      row = Row.new(component: update.name, from: update.from, to: update.to)
      case update.status
      when :would_update, :updated
        notes = [kept(update.kept, update.name), replaced(update.replaced)].compact
        done(row, :update, notes.empty? ? nil : notes.join("; "))
      when :up_to_date then up_to_date(row)
      when :skipped then skipped(row, update.note)
      else failed(row, update.note)
      end
    end

    def desktop_row(options)
      return nil unless @supported

      row = Row.new(component: "Chi Helper")
      if (why = off(options, "desktop"))
        return skipped(row, why)
      end

      helper = @platform.call(register: !options[:no_register])
      return row.tap { |r| r.status = "not installed" } unless helper.installed?

      row.from = helper.app_version
      if helper.stale?
        row.to = VERSION
        return done(row, :update, @dry_run ? "rebuilds and restarts it" : "restarted") { helper.upgrade { nil } }
      end

      return up_to_date(row) unless helper.launch_outdated?

      helper.refresh_launch_file unless @dry_run
      up_to_date(row).tap { |r| r.status += @dry_run ? " (would refresh the launch file)" : " (launch file refreshed)" }
    rescue Desktop::MacOS::Error, SystemCallError => e
      failed(row, e.message.lines.first.to_s.strip)
    end

    def live_rows
      rows = []
      stale = LiveVersions.stale_workers(VERSION, state_dir: @state_dir)
      unless stale.empty?
        versions = stale.map { |w| w.version || "an older chi" }.uniq.join(", ")
        ids = stale.map { |w| w.session_id[0, 8] }.join(" ")
        rows << Row.new(component: "workers",
                        status: "#{stale.size} live on #{versions}: they move to #{VERSION} at idle exit (30 min) " \
                                "or chi sessions stop #{ids}")
      end
      host, port = @web
      web = LiveVersions.web_version(host, port)
      if web && web != VERSION
        rows << Row.new(component: "chi web :#{port}", from: web,
                        status: "running old code: new sessions it starts run #{web} too; restart it")
      end
      rows
    end

    def footers(options)
      return [] if off(options, "bundles")

      names = MemoryBundle::ShippedUpdate.not_installed(shipped_dir: @shipped_dir).map(&:source)
      names.empty? ? [] : ["Also shipped, not installed: #{names.join(", ")} (chi bundle install NAME)"]
    end

    def summary(rows)
      return "(dry run: nothing was changed)" if @dry_run
      return "some parts failed (see above)" if rows.any?(&:failed)

      rows.all? { |r| r.status.start_with?("up to date", "skipped", "not installed", "couldn't check") } ? "everything is up to date" : "done"
    end

    # "updated" (or "would update" in a dry run), with a note; the block
    # makes the change (not in a dry run).
    def done(row, verb, note = nil)
      yield if block_given? && !@dry_run
      text = VERBS.fetch(verb)[@dry_run ? 1 : 0]
      row.status = note ? "#{text} (#{note})" : text
      row
    end

    def up_to_date(row)
      row.to = nil
      row.status = "up to date"
      row
    end

    def skipped(row, why)
      row.status = "skipped (#{why})"
      row
    end

    def failed(row, why)
      row.status = "failed (#{why})"
      row.failed = true
      row
    end

    def kept(files, bundle)
      return nil if files.empty?

      verb = @dry_run ? "would keep" : "kept"
      "#{verb} your edits in #{files.join(", ")}: chi bundle diff #{bundle} #{files.first}"
    end

    def replaced(files)
      return nil if files.empty?

      "#{@dry_run ? "would replace" : "replaced"} edited #{files.join(", ")} (it wasn't loading)"
    end

    def print_table(rows)
      header = %w[component from to status]
      cells = rows.map { |r| [r.component, r.from.to_s, r.to.to_s, r.status] }
      widths = (0..2).map { |i| ([header] + cells).map { |c| c[i].length }.max }
      ([header] + cells).each do |c|
        @stdout.puts((0..2).map { |i| c[i].ljust(widths[i]) }.join("  ") + "  " + c[3])
      end
    end
  end
end
