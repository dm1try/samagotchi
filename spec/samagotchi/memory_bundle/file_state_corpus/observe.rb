# frozen_string_literal: true

module BundleStateCorpus
  # Runs one command of a memory case on a fresh copy of its tree and reads
  # back what it left: one cell.
  #
  #   do         the file's bytes: kept, wrote_incoming, wrote_merge, restored
  #              (put back by a restore), moved (to the trash), deleted, none
  #              (absent before and after), refused (the command failed)
  #   save_first the old bytes are in the run's trash (a case has one file, so
  #              bytes equal to the old file are its copy)
  #   next_base  the base copy afterwards: old (unchanged), disk (the file's
  #              bytes now), incoming, other, none
  #   checksum   the entry's checksum afterwards, in the same words (old: as
  #              it was)
  #   mark       the entry's mark: none, set, kept, cleared; added / dropped
  #              (the record gained / lost the entry), absent (never had
  #              one); " (legacy)" when the mark left is an older chi's
  #   word       the summary line the file is on (the Installer's #summary,
  #              chi bundle uninstall's output, Remerge's lists, sync's status)
  #   label      chi bundle status NAME's line for the file afterwards ("-":
  #              no line)
  #   warns      the other lines naming the file, paths masked
  #
  # install and upgrade run the Installer, not BundleCommand: the CLI's own
  # footer (what stays behind, the agent step's prompt) isn't observed. status
  # and uninstall go through BundleCommand.
  class Observer
    def initialize(sandbox, kase)
      @sandbox = sandbox
      @case = kase
    end

    # @return [Hash] the cell
    def cell(shape, column)
      run = @sandbox.run_copy(@case, shape, column)
      @record = record_name(column)
      BundleStateCorpus.at_home(run) do
        BundleStateCorpus.with_env("SAMAGOTCHI_SKIP_SYSTEM_BUNDLE" => "1") do
          before = snapshot
          File.chmod(0o000, target) if @case.unreadable && File.exist?(target)
          outcome = send(:"run_#{column}")
          label = status_label
          readable! if @case.unreadable
          compose(column, before, snapshot, outcome, label)
        end
      end
    end

    private

    def key = @case.key
    def target = File.join(BundleStateCorpus.memories_dir, key)

    def record_name(column) = SYSTEM_COLUMNS.include?(column) ? SYSTEM : NAME

    # What the next command reads: the file, its base, its entry, the trash.
    def snapshot
      bundle = File.join(BundleStateCorpus.bundles_dir, @record)
      record = File.file?(File.join(bundle, "manifest.json")) ? JSON.parse(File.read(File.join(bundle, "manifest.json"))) : nil
      trash = Dir.glob(File.join(BundleStateCorpus.bundles_dir, ".trash", "**", "*"), File::FNM_DOTMATCH)
                 .select { |path| File.file?(path) }.map { |path| File.binread(path) }
      { disk: read(target), base: read(File.join(bundle, "bases", key)), entry: record&.dig("files", key), trash: trash }
    end

    def read(path) = File.file?(path) ? File.binread(path) : nil

    # The mode 000 file back to readable, wherever the command left it (the trash too).
    def readable!
      Dir.glob(File.join(BundleStateCorpus.memories_dir, "**", "*"), File::FNM_DOTMATCH).each do |path|
        File.chmod(0o644, path) if File.file?(path) && !File.readable?(path)
      end
    end

    def compose(column, before, after, outcome, label)
      return { "label" => label, "list" => outcome[:list] } if column == "status"

      did = bytes_did(before, after, outcome, column)
      cell = { "do" => did }
      return cell.merge("word" => outcome[:word], "warns" => outcome[:warns]) if column == "plan"

      cell.merge!("save_first" => !before[:disk].nil? && after[:trash].include?(before[:disk]),
                  "next_base" => text_word(after[:base], before[:base], after[:disk]),
                  "checksum" => checksum_word(after[:entry], before, after[:disk]),
                  "mark" => mark_word(before[:entry], after[:entry]),
                  "word" => outcome[:word], "label" => label, "warns" => outcome[:warns])
      cell["via"] = outcome[:via] if outcome[:via]
      cell
    end

    def bytes_did(before, after, outcome, column)
      was = before[:disk]
      now = after[:disk]
      changed = if was.nil? && now.nil? then "none"
                elsif now.nil? then after[:trash].include?(was) ? "moved" : "deleted"
                elsif was == now then "kept"
                elsif now == @case.incoming then was.nil? && column == "restore" ? "restored" : "wrote_incoming"
                else "wrote_merge"
                end
      return changed unless outcome[:refused]

      %w[kept none].include?(changed) ? "refused" : "#{changed}, then refused"
    end

    # A text afterwards, by what it equals: old (as before), disk, incoming.
    def text_word(now, was, disk)
      return "none" if now.nil?
      return "old" if now == was
      return "disk" if now == disk
      return "incoming" if now == @case.incoming

      "other"
    end

    def checksum_word(entry, before, disk)
      now = entry&.fetch("checksum", nil)
      return "none" if now.nil? || now.empty?
      return "old" if now == before[:entry]&.fetch("checksum", nil)
      return "disk" if disk && now == BundleStateCorpus.sha(disk)
      return "incoming" if @case.incoming && now == BundleStateCorpus.sha(@case.incoming)

      "other"
    end

    def mark_word(was, now)
      word = if was.nil? then now.nil? ? "absent" : "added"
             elsif now.nil? then "dropped"
             elsif was["conflict"] && now["conflict"] then "kept"
             elsif now["conflict"] then "set"
             elsif was["conflict"] then "cleared"
             else "none"
             end
      legacy = Samagotchi::MemoryBundle::InstalledBundle.legacy_mark?(now&.transform_keys(&:to_sym))
      legacy ? "#{word} (legacy)" : word
    end

    # chi bundle status NAME's line for the file.
    def status_label
      out = StringIO.new
      Samagotchi::BundleCommand.new(["status", @record], stdout: out, stderr: StringIO.new).run
      return "not installed" if out.string.include?("not installed.")

      line = out.string.lines.map(&:chomp).find { |text| text.start_with?("  #{key}: ") }
      line ? @sandbox.mask(line.delete_prefix("  #{key}: ")) : "-"
    end

    # ── the commands ───────────────────────────────────────────────

    def run_install = installer
    def run_install_force = installer(force: true)
    def run_install_dry = installer(dry_run: true)
    def run_upgrade = installer(upgrade: true)
    def run_upgrade_force = installer(upgrade: true, force: true)
    def run_upgrade_dry = installer(upgrade: true, dry_run: true)
    def run_remerge = remerge(dry_run: false)
    def run_remerge_dry = remerge(dry_run: true)
    def run_uninstall = uninstall([])
    def run_uninstall_force = uninstall(["--force"])

    def installer(**)
      installer = Samagotchi::MemoryBundle::Installer.new(source: @sandbox.source(@case), name: NAME, strict: true, **)
      refused = begin
        installer.run
        nil
      rescue Samagotchi::MemoryBundle::Installer::InstallError => e
        e.message
      end
      lines = installer.summary.lines.map(&:chomp)
      side = installer.warnings + installer.placeholder_warnings + [installer.trash_copy_line].compact
      words = lines - side
      word = words.filter_map { |line| word_of(line) }.first
      warns = (lines - words.select { |line| word_of(line) == word }).select { |line| names_file?(line) }
      warns << refused if refused
      { word: word, warns: warns.map { |line| @sandbox.mask(line) }.uniq, refused: refused }
    end

    # The label of a "Label: a.md, b.md" line (or a merged line) that lists the file.
    def word_of(line)
      if (merged = line.match(/\A(merged|would merge)(?: \S+)? into your (.*)\z/))
        return merged[2].split(", ").include?(key) ? merged[1] : nil
      end

      label, list = line.split(": ", 2)
      return nil unless list

      list.sub(/ \((?:moved to|<tmp>).*\)\z/, "").sub(/ \(#{Regexp.escape(@sandbox.root)}.*\)\z/, "").split(", ").include?(key) ? label : nil
    end

    # A line about the file: it names it, or it is the re-install line
    # saying the user's own copies were kept.
    def names_file?(line) = line.include?(key) || line.include?("your own copies of its memories were kept")

    def uninstall(flags)
      out = StringIO.new
      err = StringIO.new
      status = Samagotchi::BundleCommand.new(["uninstall", NAME, *flags], stdout: out, stderr: err).run
      lines = (out.string.lines + err.string.lines).map(&:chomp)
      word = lines.filter_map { |line| word_of(line) }.first
      warns = lines.reject { |line| word && word_of(line) == word }.select { |line| line.include?(key) || status != 0 }
      { word: word, warns: warns.map { |line| @sandbox.mask(line) }, refused: status != 0 }
    end

    def remerge(dry_run:)
      done = Samagotchi::MemoryBundle::Remerge.new(name: SYSTEM, scope: "system", target_dir: BundleStateCorpus.memories_dir,
                                                   source_dir: @sandbox.same_source(@case)).run(dry_run: dry_run)
      word = { "merged" => done.merged, "settled" => done.settled, "stamped" => done.stamped }
             .select { |_, files| files.include?(key) }.keys
      behind = done.behind.select { |file| file.file == key }
      word << "behind" if behind.any?
      { word: word.empty? ? nil : word.join(", "), warns: masked(behind.map { |file| file.line(dry_run: dry_run) } + done.warnings.select { |w| w.include?(key) }) }
    end

    def run_restore
      result = BundleStateCorpus.with_env("SAMAGOTCHI_SKIP_SYSTEM_BUNDLE" => nil) { Samagotchi::MemoryBundle::SystemBundle.sync }
      behind = Array(result.behind).select { |file| file.file == key }.map(&:line)
      warns = behind + Array(result.warnings).select { |w| w.include?(key) } + [result.error].compact
      { word: result.status.to_s, warns: masked(warns), via: %i[up_to_date merged].include?(result.status) ? "remerge" : nil,
        refused: result.status == :failed }
    end

    # chi update's plan row for the bundle: its status, and whether it names
    # the file as merged, behind or replaced.
    def run_plan
      path = File.join(BundleStateCorpus.bundles_dir, NAME, "manifest.json")
      if File.file?(path)
        raw = JSON.parse(File.read(path))
        File.write(path, JSON.pretty_generate(raw.merge("source" => SHIPPED_LOOKING)))
      end
      rows = Samagotchi::MemoryBundle::ShippedUpdate.plan(shipped_dir: File.dirname(@sandbox.source(@case)))
      row = rows.find { |candidate| candidate.name == NAME }
      return { word: "no row", warns: [] } unless row

      named = { "merges" => row.merged, "behind" => Array(row.behind).map(&:file), "replaces" => row.replaced }
              .select { |_, files| files.include?(key) }.keys
      behind = Array(row.behind).select { |file| file.file == key }.map(&:line)
      { word: [row.status.to_s, *named].join(", "), warns: masked(behind + [row.note].compact) }
    end

    def run_status
      installed = Samagotchi::MemoryBundle::Listing.installed(shipped: []).find { |bundle| bundle.name == NAME }
      behind = installed&.behind || []
      list = behind.empty? ? nil : Samagotchi::MemoryBundle::FileStanding.behind_count(behind.size, unsure: behind.any?(&:unsure))
      { list: list }
    end

    def masked(lines) = lines.map { |line| @sandbox.mask(line) }
  end
end
