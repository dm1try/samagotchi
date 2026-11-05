# frozen_string_literal: true

require_relative "cli/command"
require_relative "cli/flags"
require_relative "chi_home"
require_relative "child_env"
require_relative "config"
require_relative "desktop"
require_relative "gem_update"
require_relative "installed_gem"
require_relative "live_versions"
require_relative "memory_bundle/file_standing"
require_relative "memory_bundle/shipped_update"
require_relative "memory_bundle/system_bundle"
require_relative "session"
require_relative "version"
require_relative "web/lan"
require_relative "web/running"
require "json"

module Samagotchi
  # `chi update`: brings an installed chi up to date in one go: the system
  # bundle, the shipped bundles the user installed, and the macOS helper.
  # Unedited things update; edited ones merge or stay behind (.md) or are replaced
  # and reported (hooks, plugin, rules, which didn't load once edited). Live
  # workers and a running chi web are reported, never restarted. The bundles
  # chi didn't ship are only checked, under the chi that will run them
  # (BundleCommand::InstalledCheck): what it finds is rows that fail nothing.
  # Prints one table; a second run changes nothing and says so.
  class UpdateCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi update [--dry-run] [--to VERSION] [--json] [--no-gem] [--no-bundles] [--no-desktop]
        Updates this chi's install: the gem (from rubygems.org), then the
        system bundle, the bundles chi ships that you installed (chi bundle
        list), and the desktop helper (macOS; rebuilt only when its sources
        changed). A memory file you edited takes the update in a text merge
        (the old file goes to the bundle trash), or stays behind as it is when
        no merge is possible, and the table says which and why; each run
        retries a file left behind, though one an older chi marked, with a base
        no installed chi shipped, merges only if the bundle takes out or rewords
        no line it still holds. Nothing is
        installed that isn't already, and old gem versions stay. The bundles chi doesn't ship are
        never changed: the new chi checks them and adds a row per warning or
        error (these don't fail the update).
        --dry-run      show what would change; change nothing (with a newer
                       gem to install, bundles chi doesn't ship aren't checked:
                       that chi would)
        --to VERSION   install exactly this gem version (must be newer than this chi)
        --json         print update rows as one JSON document
        --no-gem       don't install a newer gem (config update.gem: false)
        --no-bundles   leave all bundles alone, unchecked too (config update.bundles: false)
        --no-desktop   leave the desktop helper alone (config update.desktop: false)
        Running sessions keep their chi until restarted (chi sessions
        restart ID) or until they idle out with nothing attached; a running
        chi web needs a restart (the sessions it starts run the new chi).
    TEXT

    # Help is a flag here: it doesn't stop the parse (an unknown option
    # after it is still an error).
    FLAGS = CLI::Flags.new(args: false) do |f|
      f.switch "-h", "--help", "help"
      f.switch "--dry-run"
      f.value "--to"
      f.switch "--json"
      f.switch "--no-gem"
      f.switch "--no-bundles"
      f.switch "--no-desktop"
      # Hidden: no pbs/lsregister/open/pkill for a helper under HOME=<tmp>.
      f.switch "--no-register"
      # Hidden: the old version, passed by the chi that installed this one.
      f.value "--gem-from"
    end
    # "1" in a chi update another chi exec'd into the chi home (#to_home):
    # it doesn't exec again. An env marker, not a flag: the home's chi may
    # be older than the one exec'ing it, and refuse a flag it doesn't know.
    IN_HOME_ENV = "SAMAGOTCHI_UPDATE_IN_HOME"
    # The switches the newer gem's update gets again (hand_over).
    HANDED_OVER = { "--no-gem" => :no_gem, "--no-bundles" => :no_bundles, "--no-desktop" => :no_desktop,
                    "--no-register" => :no_register, "--to" => :to, "--json" => :json }.freeze

    # A table row. info rows (live workers, chi web) say what runs; they
    # never fail. level ("warn", "error"; else nil) marks a finding on a bundle
    # chi didn't ship: it reports, changes nothing and fails nothing. kept: the
    # memory files that stay behind; merged: the ones that took the update;
    # trash_copy: where their old copies went, in full (the table's short: --json
    # has the path); earlier: the files of the earlier merges the row names.
    Row = Struct.new(:component, :from, :to, :status, :failed, :kept, :merged, :earlier, :trash_copy, :level, keyword_init: true)

    # What a row says after a change, and in a dry run.
    VERBS = { update: ["updated", "would update"], install: ["installed", "would install"],
              restore: ["restored missing files", "would restore missing files"] }.freeze

    # @param gem_spec [Gem::Specification, nil] the installed gem (nil: a checkout)
    # @param platform [#call] register: → a Desktop::MacOS-like object
    # @param exec [#call] argv → replaces this process (the new chi's update)
    # @param bundler [Boolean] running under Bundler (bundle exec)
    # @param home [#current, #record_first!] the chi home (ChiHome)
    # @param env [Hash] IN_HOME_ENV is taken out of it
    def initialize(argv, stdout: $stdout, stderr: $stderr, gem_spec: InstalledGem.spec,
                   shipped_dir: MemoryBundle::SourceNormalizer::SHIPPED_DIR, platform: nil,
                   supported: Desktop.supported?, state_dir: Session.default_state_dir, web: nil,
                   gem_update: nil, exec: nil, bundler: nil, home: ChiHome, env: ENV)
      @home = home
      @in_home = env.delete(IN_HOME_ENV) == "1"
      @unattended = env[ChildEnv::UNATTENDED_UPDATE] == "1"
      # Built after the home is known: its install env goes into the home.
      @gem_update_given = gem_update
      @exec = exec || ->(argv) { Kernel.exec(*argv) }
      @bundler = bundler.nil? ? ChiHome.under_bundler? : bundler
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @gem_spec = gem_spec
      @shipped_dir = shipped_dir
      @platform = platform || Desktop::MacOS.method(:from_config)
      @supported = supported
      @state_dir = state_dir
      @web = web || [Web::Lan.local_host(Config.get("web.host")), LiveVersions.configured_web_port]
    end

    # @return [Integer] 0 nothing failed, 1 a part failed (or a checkout), 2 usage
    def run
      options = parse
      return options if options.is_a?(Integer)

      if options[:help]
        @stdout.puts(USAGE)
        return 0
      end
      return usage_error("invalid version #{options[:to]}") if options[:to] && !Gem::Version.correct?(options[:to])

      # The home's chi decides the rest (--to's floor included); never from
      # a checkout (ChiHome.current is nil there).
      @run_home = @gem_spec && @home.current(gem_spec: @gem_spec)
      return to_home(options) if away_from_home?(options)

      if options[:to] && !options[:gem_from] && Gem::Version.new(options[:to]) <= Gem::Version.new(VERSION)
        @stderr.puts("chi update: #{options[:to]} is not newer than the running chi (#{VERSION})")
        return 1
      end

      unless @gem_spec
        @stderr.puts("chi update: running from a checkout (#{InstalledGem::ROOT}): chi update updates an installed chi; " \
                     "git pull, or chi bundle upgrade NAME for one bundle")
        return 1
      end

      # No home yet: the first record, once this chi's own checks passed.
      @run_home ||= record_home(options)
      return to_home(options) if away_from_home?(options)

      @gem_update = @gem_update_given ||
                    GemUpdate.new(gem_bin: ChiHome.gem_bin(@run_home), install_env: ChiHome.install_env(@run_home))
      @dry_run = options[:dry_run]
      gem = gem_row(options)
      rows = [gem, system_bundle_row, *bundle_rows(options), *external_rows(options), desktop_row(options), *live_rows].compact
      if options[:json]
        @stdout.puts(JSON.generate(rows.map { |row| row.to_h.merge(failed: !!row.failed, kept: row.kept || [], merged: row.merged || [], earlier: row.earlier || []) }))
      else
        print_table(rows)
        footers(options, rows).each { |line| @stdout.puts(line) }
        @stdout.puts(summary(rows))
      end
      rows.any?(&:failed) ? 1 : 0
    end

    private

    def command_name = "chi update"

    # Whether this run is on another Ruby than the chi home's, and not one
    # another chi exec'd or handed over to.
    def away_from_home?(options) = @run_home && !@in_home && !options[:gem_from] && !@run_home.running_here?

    # The first chi home (ChiHome.record_first!: the helper's Ruby or this
    # one, whichever has the newer chi), said once. Not in a dry run, a run
    # another chi exec'd or handed over to, nor under Bundler.
    def record_home(options)
      return nil if options[:dry_run] || @in_home || options[:gem_from] || @bundler

      recorded = @home.record_first!(gem_spec: @gem_spec, launch_path: helper_launch_path, bundler: false)
      notice(options, "chi home set to #{recorded.ruby} (chi home set to change)") if recorded
      recorded
    end

    # A chi on another Ruby than the home's updates the home: exec its chi
    # (newer?, --to and the bundle rows are then the home's), once
    # (IN_HOME_ENV), outside a `bundle exec`'s bundle (ChildEnv.unbundled,
    # as worker spawns and chi web's restart boot it). hand_over never runs
    # under Bundler: the gem row skips there.
    def to_home(options)
      notice(options, "updating the chi home (#{@run_home.ruby})")
      @stdout.flush
      @exec.call([ChildEnv.unbundled.merge(IN_HOME_ENV => "1"), *@run_home.boot_argv(run: ChiHome::CHI_BOOT), "--",
                  "update", *@argv])
      0 # only when exec is a spec's stand-in
    end

    def notice(options, text) = (options[:json] ? @stderr : @stdout).puts(text)

    def helper_launch_path
      return nil unless @supported

      helper = @platform.call(register: false)
      helper.respond_to?(:launch_path) ? helper.launch_path : nil
    rescue StandardError
      nil
    end

    # @return [Hash, Integer] the options, or the usage error's exit status
    #   (every error reads "unknown option", a --gem-from without its value too)
    def parse
      parsed = FLAGS.parse(@argv)
      return usage_error("unknown option #{parsed.error.arg}") if parsed.error

      parsed.options
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
      why = off(options, "gem") || ("under Bundler: bundle update samagotchi" if @bundler)
      # --to asks for that exact version: not installing it is a failure, not a skip.
      return options[:to] ? failed(row, "skipped: #{why}") : skipped(row, why) if why

      latest = begin
        if options[:to]
          if ENV[GemUpdate::LOCAL_ENV].to_s.empty?
            GemUpdate::Latest.new(version: options[:to], source: "samagotchi")
          else
            local = @gem_update.latest
            return failed(row, "local gem file is #{local.version}, not #{options[:to]}") unless local.version == options[:to]

            local
          end
        else
          @gem_update.latest
        end
      rescue GemUpdate::Error => e
        return row.tap { |r| r.status = "couldn't check (#{e.message})" }
      end
      return up_to_date(row) unless options[:to] || @gem_update.newer?(latest)

      row.to = latest.version
      if @dry_run
        @not_checked = "chi #{latest.version} checks them once installed"
        return done(row, :update)
      end

      (options[:json] ? @stderr : @stdout).puts("installing samagotchi #{latest.version}…")
      output, ok = @gem_update.install(latest)
      return failed(row, output.lines.map(&:strip).reject(&:empty?).last.to_s) unless ok

      hand_over(options, row, latest.version)
    end

    # exec the newest installed samagotchi: the chi home's boot, else the
    # wrapper. Without either (installed with --bindir), this version syncs.
    def hand_over(options, row, version)
      wrapper = InstalledGem.wrapper(@gem_spec) unless @run_home
      unless @run_home || wrapper
        @not_checked = "chi #{version} checks them: run chi update again"
        return done(row, :update, "run chi update again to sync with it")
      end

      passed = options[:to] ? ["--to", options[:to]] : []
      passed += HANDED_OVER.except("--to").select { |_, key| options[key] }.keys
      args = ["update", "--no-gem", "--gem-from", VERSION, *passed]
      @stdout.flush
      @exec.call(@run_home ? @run_home.boot_argv(run: ChiHome::CHI_BOOT) + ["--", *args] : [RbConfig.ruby, wrapper, *args])
      done(row, :update) # only when exec is a spec's stand-in
    end

    # Why a part is off for this run, or nil.
    def off(options, part)
      return "--no-#{part}" if options[:"no_#{part}"]
      return "update.#{part}: false" unless Config.get("update.#{part}")

      nil
    end

    def system_bundle_row
      system = MemoryBundle::SystemBundle
      earlier = system.merge_notes
      result = system.sync(dry_run: @dry_run)
      # These rows have no place for the notes, which wait for one that has.
      earlier = [] if %i[installed skipped failed].include?(result.status)
      row = Row.new(component: "system bundle", from: result.from, to: result.to)
      notes = file_notes(row, system::BUNDLE_NAME, result.to, result.merged, result.behind, result.trash_copy, earlier: earlier)
      case result.status
      when :installed then done(row, :install)
      when :updated then done(row, :update, notes.empty? ? nil : notes.join("; "))
      when :restored then done(row, :restore, notes.empty? ? nil : notes.join("; ")).tap { |r| r.to = nil }
      when :merged, :up_to_date then same_version(row, notes + result.warnings, changed: result.merged.any?)
      when :newer_installed then skipped(row, ["newer than this chi's #{result.to}: left", *notes].join("; ")).tap { |r| r.to = nil }
      when :skipped then skipped(row, result.error)
      else failed(row, result.error)
      end
      system.clear_merge_notes(earlier, files: result.merged) if read_by_someone?
      row
    end

    def bundle_rows(options)
      if (why = off(options, "bundles"))
        return [Row.new(component: "bundles", status: "skipped (#{why})")]
      end

      rows = MemoryBundle::ShippedUpdate.plan(shipped_dir: @shipped_dir)
      rows = MemoryBundle::ShippedUpdate.apply(rows) unless @dry_run
      rows.map { |r| bundle_row(r) }
    end

    # The bundles chi doesn't ship, checked by the chi that will run them: this
    # one, but when a newer gem is yet to take over (@not_checked: a dry run,
    # or no way to hand over). The run handed over to is the new chi's own.
    def external_rows(options)
      return [] if off(options, "bundles")

      bundles = MemoryBundle::ShippedUpdate.external(shipped_dir: @shipped_dir)
      return [] if bundles.empty?
      return [Row.new(component: "external bundles", status: "not checked (#{@not_checked})")] if @not_checked

      require_relative "bundle_command/installed_check"
      bundles.flat_map do |bundle|
        BundleCommand::InstalledCheck.run(bundle).map { |found| Row.new(component: bundle.name, status: found.text, level: found.level) }
      end
    end

    def bundle_row(update)
      row = Row.new(component: update.name, from: update.from, to: update.to)
      earlier = update.status == :failed ? [] : Array(update.earlier)
      notes = file_notes(row, update.name, update.to || update.from, update.merged, update.behind, update.trash_copy, earlier: earlier)
      case update.status
      when :would_update, :updated
        notes = [adds(update.adds), *notes, replaced(update.replaced), *update.kept_own].compact
        done(row, :update, notes.empty? ? nil : notes.join("; "))
      when :would_merge, :merged, :up_to_date then same_version(row, [*notes, update.note].compact, changed: Array(update.merged).any?)
      when :skipped then skipped(row, [update.note, *notes].join("; "))
      else failed(row, [update.note, *notes].compact.join("; "))
      end
      # A failed row keeps them: the run didn't finish, and the next says what stands.
      MemoryBundle::Provenance.new(name: update.name).clear_merge_notes(earlier, files: row.merged) if read_by_someone? && update.status != :failed
      row
    end

    # What one bundle's memory files did, in FileStanding's words; the row keeps
    # the file names and the trash copy's full line for --json. merged is what
    # this run merged, earlier the files of the notes it shows.
    # @return [Array<String>] the row's clauses
    def file_notes(row, bundle, version, merged, behind, trash_copy, earlier: [])
      merged = Array(merged)
      behind = Array(behind)
      row.merged = merged
      row.earlier = earlier.map(&:file)
      row.kept = behind.map(&:file)
      @unsure_behind ||= behind.any?(&:unsure)
      row.trash_copy = trash_copy
      notes = MemoryBundle::FileStanding.clauses(bundle, version, merged: merged, behind: behind, earlier: earlier, dry_run: @dry_run)
      trash_copy || earlier.any?(&:trash) ? [*notes, MemoryBundle::FileStanding::IN_THE_TRASH] : notes
    end

    # Whether a row printed now ends the notes for what it printed, this run's
    # merges too. A dry run changes nothing, and an automatic update's rows may be
    # read by no one (ChildEnv::UNATTENDED_UPDATE).
    def read_by_someone? = !@dry_run && !@unattended

    # A row at the same version: up to date only when nothing merged and nothing
    # stays behind. No to, and no verb of its own: the clauses say it all.
    def same_version(row, notes, changed:)
      return up_to_date(row, notes.join("; ")) unless changed || row.kept.any?

      row.to = nil
      row.status = notes.join("; ")
      row
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
      if (problem = helper.launch_problem)
        return failed(row, problem)
      end

      if helper.launch_newer?
        return up_to_date(row).tap { |r| r.status += " (kept: chi #{helper.launch_version} set it up; this chi is older)" }
      end

      if helper.stale?
        row.to = VERSION
        done(row, :update, @dry_run ? "rebuilds and restarts it" : "restarted") { helper.upgrade(keep_launch: true) { nil } }
      elsif helper.launch_outdated?
        helper.refresh_launch_file unless @dry_run
        up_to_date(row).tap { |r| r.status += @dry_run ? " (would refresh the launch file)" : " (launch file refreshed)" }
      else
        up_to_date(row)
      end
      # The terminals' warnings only: the host key ones read the Keychain.
      helper.terminal_warnings.each { |warning| row.status += "; #{warning}" }
      row
    rescue Desktop::MacOS::Error, SystemCallError => e
      failed(row, e.message.lines.first.to_s.strip)
    end

    def live_rows
      rows = []
      stale = LiveVersions.stale_workers(VERSION, state_dir: @state_dir)
      rows << Row.new(component: "workers", status: workers_status(stale)) unless stale.empty?
      host, configured = @web
      answer = LiveVersions.web_answering(host, configured, path: Web::Running.path(state_dir: @state_dir))
      web = answer&.info&.fetch("version", nil).to_s
      if !web.empty? && web != VERSION
        # Since newest_workers, the sessions it starts run the newest chi.
        spreads = !Array(answer.info["features"]).include?("newest_workers")
        rows << Row.new(component: "chi web :#{answer.port}", from: web,
                        status: "running old code#{": new sessions it starts run #{web} too" if spreads}; restart it")
      end
      rows
    end

    # A worker keeps its chi until restarted: `chi sessions restart` for
    # one that can, a stop for an older one (the next prompt starts it on
    # the newest). It idles out on its own only with nothing attached.
    def workers_status(stale)
      versions = stale.map { |w| w.version || "an older chi" }.uniq.join(", ")
      restart, stop = stale.partition(&:restart).map { |ws| ws.map { |w| w.session_id[0, 8] }.join(" ") }
      moves = []
      moves << "chi sessions restart #{restart}" unless restart.empty?
      moves << "chi sessions stop #{stop}" unless stop.empty?
      "#{stale.size} live on #{versions}: they keep it until restarted (#{moves.join("; ")})#{idle_note}"
    end

    def idle_note
      minutes = begin
        Config.get("session.idle_exit_minutes").to_f
      rescue StandardError
        30.0
      end
      return "; they never idle out (session.idle_exit_minutes: 0)" unless minutes.positive?

      "; or they idle out after #{minutes.round(1).to_s.delete_suffix(".0")} min with nothing attached"
    end

    def footers(options, rows)
      return [] if off(options, "bundles")

      lines = rows.any?(&:level) ? ["Bundles not from chi are left as they are: their author's next version, or chi bundle upgrade NAME, is what changes them"] : []
      names = MemoryBundle::ShippedUpdate.not_installed(shipped_dir: @shipped_dir).map do |s|
        s.includes.empty? ? s.source : "#{s.source} (#{s.includes.join(", ")})"
      end
      lines << "Also shipped, not installed: #{names.join(", ")} (chi bundle install NAME)" unless names.empty?
      lines
    end

    def summary(rows)
      return "(dry run: nothing was changed)" if @dry_run
      return "some parts failed (see above)" if rows.any?(&:failed)

      behind = rows.sum { |row| Array(row.kept).size }
      return "#{MemoryBundle::FileStanding.stay_behind(behind, unsure: @unsure_behind)} (see above)" if behind.positive?

      # A finding on a bundle chi didn't ship repeats until its bundle changes; it isn't a change.
      changes = rows.reject(&:level)
      changes.all? { |r| r.status.start_with?("up to date", "skipped", "not installed", "couldn't check") } ? "everything is up to date" : "done"
    end

    # "updated" (or "would update" in a dry run), with a note; the block
    # makes the change (not in a dry run).
    def done(row, verb, note = nil)
      yield if block_given? && !@dry_run
      text = VERBS.fetch(verb)[@dry_run ? 1 : 0]
      row.status = note ? "#{text} (#{note})" : text
      row
    end

    def up_to_date(row, note = nil)
      row.to = nil
      row.status = note.to_s.empty? ? "up to date" : "up to date (#{note})"
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

    # A profile's new members: "+ btw".
    def adds(members)
      members.nil? || members.empty? ? nil : "+ #{members.join(", ")}"
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
