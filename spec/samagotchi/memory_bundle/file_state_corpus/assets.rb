# frozen_string_literal: true

require "samagotchi/memory_bundle/asset_state"

module BundleStateCorpus
  ASSET_COLUMNS = %w[install upgrade upgrade_dry uninstall plan status].freeze
  ASSET_STATES = %w[new unchanged pristine edited_sha edited_no_sha dev_link dropped_pristine dropped_edited].freeze
  ASSETS = %w[rule plugin script hook].freeze
  HOOK_META = { "event" => "before_tool_call" }.freeze

  AssetCase = Data.define(:id, :asset, :state, :file, :recorded, :installed, :incoming, :beside, :listed_missing,
                          :unlisted, :linked, :fix, :fixed, :divergent, :changed, :note) do
    def dev? = recorded == "dev"

    # Where it lives in the source.
    def source_rel = { "rule" => "guardrails/r.yml", "plugin" => "plugin.rb", "script" => "scripts/s.sh", "hook" => "hooks/#{file}" }.fetch(asset)

    # Its name in the bundle's folder, the trash, a plan's replaced and uninstall's Removed.
    def label = asset == "plugin" ? "plugin/plugin.rb" : source_rel

    # Its name in the Installer's summary.
    def result_key = { "rule" => "guardrails/r.yml", "plugin" => "plugin.rb", "script" => "scripts/s.sh", "hook" => "hooks/#{file}" }.fetch(asset)
  end

  module Examples
    def expect_asset_cells(goldens, kase) = expect_cells(goldens, kase, AssetObserver.new(@sandbox, kase), ASSET_COLUMNS)
  end

  module_function

  def asset_cases
    @asset_cases ||= begin
      data = YAML.safe_load_file(File.join(FIXTURES, "asset_cases.yml"))
      texts = data.fetch("texts")
      text = ->(value) { value.nil? || value == "" || value == "dev" ? value : texts.fetch(value) }
      data.fetch("cases").map do |row|
        AssetCase.new(id: row.fetch("id"), asset: row.fetch("asset"), state: row.fetch("state"), file: row.fetch("file", "h.rb"),
                      recorded: text.call(row["recorded"]), installed: text.call(row["installed"]), incoming: text.call(row["incoming"]),
                      beside: row.fetch("beside", false), listed_missing: row.fetch("listed_missing", false),
                      unlisted: row.fetch("unlisted", false), linked: row.fetch("linked", false), fix: row.fetch("fix", []),
                      fixed: row["fixed"], divergent: row["divergent"], changed: row["changed"], note: row["note"])
      end
    end
  end

  # The asset cases' trees: a bundle at 1.0.0 with the case's file in its
  # folder, the source at 1.1.0 beside it.
  class AssetSandbox < Sandbox
    def source(kase)
      dir = File.join(@root, "src", kase.id, "v2", NAME)
      return dir if File.directory?(dir)

      write_bundle(kase, dir, "1.1.0", kase.incoming, link: kase.linked, listed: kase.incoming || kase.listed_missing,
                                                      beside: kase.beside && (kase.incoming || kase.listed_missing))
      dir
    end

    private

    # The bundle as first installed: its manifest.yml is the kept one.
    def first_source(kase)
      dir = File.join(@root, "src", kase.id, "v1", NAME)
      return dir if File.directory?(dir)

      text = kase.recorded.is_a?(String) && !kase.recorded.empty? && !kase.dev? ? kase.recorded : kase.installed
      write_bundle(kase, dir, "1.0.0", kase.recorded.nil? ? nil : text, link: false, listed: !kase.recorded.nil?, beside: kase.beside)
      dir
    end

    # A bundle dir: its manifest, the case's file (+text+; a link out of the
    # dir with +link+; listed in the manifest with +listed+) and, with
    # +beside+, an unchanged hooks/h.rb. A hook case's source (v2) ships its
    # hook only when the case's incoming has one (or the manifest lists one
    # it lacks): that source is refused; without, an install or upgrade
    # retires the record's hooks. v1 is the kept manifest.yml, hooks: and all.
    def write_bundle(kase, dir, version, text, link:, listed:, beside:)
      FileUtils.mkdir_p(dir)
      manifest = { "name" => NAME, "version" => version, "scope" => "system" }
      hooks = {}
      if beside
        write(File.join(dir, "hooks", "h.rb"), "# v1\n")
        hooks["h.rb"] = HOOK_META.merge("sha256" => "sha256:#{BundleStateCorpus.sha("# v1\n")}")
      end
      path = File.join(dir, kase.source_rel)
      if text && link
        outside = scratch_file("outside-#{kase.id}/#{File.basename(path)}", text)
        FileUtils.mkdir_p(File.dirname(path))
        File.symlink(outside, path)
      elsif text
        write(path, text)
        FileUtils.chmod(0o755, path) if kase.asset == "script" # as a bundle ships it: a dev link runs it
      end
      sha = text ? "sha256:#{BundleStateCorpus.sha(text)}" : ""
      case kase.asset
      when "plugin" then manifest["plugin"] = { "file" => "plugin.rb", "sha256" => sha } if text
      when "script" then manifest["scripts"] = { "s.sh" => sha } if text
      when "hook" then hooks[kase.file] = HOOK_META.merge("sha256" => sha) if listed && !kase.unlisted && kase.state != "stray"
      end
      manifest["hooks"] = hooks unless hooks.empty?
      File.write(File.join(dir, "manifest.yml"), YAML.dump(manifest))
    end

    def write(path, text)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end

    def build_template(kase, shape, _flavor)
      home = File.join(@root, "templates", kase.id, shape)
      FileUtils.mkdir_p(File.join(home, "samagotchi"))
      FileUtils.cp(File.join(SPEC_XDG_CONFIG_HOME, "samagotchi", "config.yml"), File.join(home, "samagotchi", "config.yml"))
      BundleStateCorpus.at_home(home) do
        FileUtils.mkdir_p(BundleStateCorpus.memories_dir)
        write_asset_record(kase)
        Shapes.v149!(BundleStateCorpus.bundles_dir) if shape == "0.149"
      end
      home
    end

    # The installed file (a dev install's a link to the source's), then
    # today's Provenance#write, then the recorded sha as the case says.
    def write_asset_record(kase)
      provenance = Samagotchi::MemoryBundle::Provenance.new(name: NAME)
      installed = File.join(provenance.bundle_dir, kase.label)
      if kase.dev?
        FileUtils.mkdir_p(File.dirname(installed))
        File.symlink(File.realpath(File.join(source(kase), kase.source_rel)), installed)
      elsif kase.installed
        write(installed, kase.installed)
      end
      FileUtils.chmod(0o755, installed) if kase.asset == "script" && kase.installed && !kase.dev?
      beside = File.join(provenance.hooks_dir, "h.rb")
      write(beside, "# v1\n") if kase.beside
      recorded = kase.recorded.nil? ? nil : installed
      provenance.write(files: {}, scope: "system", version: "1.0.0", source_path: source(kase),
                       guardrails_files: kase.asset == "rule" && recorded ? { "r.yml" => recorded } : {},
                       plugin_file: kase.asset == "plugin" && recorded ? recorded : nil,
                       scripts_files: kase.asset == "script" && recorded ? { "s.sh" => recorded } : {},
                       dev: kase.dev?, manifest_from: first_source(kase))
      hooks = kase.beside ? { "h.rb" => { text: nil, meta: HOOK_META } } : {}
      hooks[kase.file] = { text: nil, meta: HOOK_META } if kase.asset == "hook" && recorded
      LegacyHooksRecord.legacy_hooks_record(NAME, hooks: hooks) unless hooks.empty?
      return if kase.recorded.nil? || kase.dev?

      path = File.join(provenance.bundle_dir, "manifest.json")
      raw = JSON.parse(File.read(path))
      entry = AssetObserver.entry(raw, kase)
      entry["sha256"] = kase.recorded.empty? ? "" : "sha256:#{BundleStateCorpus.sha(kase.recorded)}"
      File.write(path, JSON.pretty_generate(raw))
    end
  end

  # One asset command on a fresh copy of the case's tree: one cell.
  #
  #   do         the installed file: kept, wrote_incoming, wrote_other, removed,
  #              none, refused; " (link)" when what is left is a link
  #   save_first the old bytes are in the run's trash
  #   recorded   its sha in the record afterwards: old, incoming, disk, empty
  #              (recorded, no sha), dev, none (not recorded), other
  #   word       the summary line naming it (the Installer's #summary, chi
  #              bundle uninstall's Removed:); a plan's row status, and
  #              "replaces" when its replaced lists the file
  #   label      chi bundle status NAME's line for it ("-": none)
  #   warns      the other lines naming it, paths masked
  class AssetObserver
    def self.entry(raw, kase)
      case kase.asset
      when "rule" then raw.dig("guardrails", "r.yml")
      when "plugin" then raw["plugin"]
      when "script" then raw.dig("scripts", "s.sh")
      else raw.dig("hooks", kase.file)
      end
    end

    def initialize(sandbox, kase)
      @sandbox = sandbox
      @case = kase
    end

    def cell(shape, column)
      run = @sandbox.run_copy(@case, shape, column)
      BundleStateCorpus.at_home(run) do
        BundleStateCorpus.with_env("SAMAGOTCHI_SKIP_SYSTEM_BUNDLE" => "1") do
          before = snapshot
          outcome = send(:"run_#{column}")
          label = status_label
          after = snapshot
          next { "label" => label } if column == "status"

          did = bytes_did(before, after, outcome)
          next { "do" => did, "word" => outcome[:word], "warns" => outcome[:warns] } if column == "plan"

          { "do" => did, "save_first" => !before[:bytes].nil? && !before[:link] && after[:trash].include?(before[:bytes]),
            "recorded" => recorded_word(before[:sha], after), "word" => outcome[:word], "label" => label, "warns" => outcome[:warns] }
        end
      end
    end

    private

    def path = File.join(BundleStateCorpus.bundles_dir, NAME, @case.label)

    def snapshot
      record = File.join(BundleStateCorpus.bundles_dir, NAME, "manifest.json")
      raw = File.file?(record) ? JSON.parse(File.read(record)) : nil
      trash = Dir.glob(File.join(BundleStateCorpus.bundles_dir, ".trash", "**", "*"), File::FNM_DOTMATCH)
                 .select { |file| File.file?(file) }.map { |file| File.binread(file) }
      { bytes: File.file?(path) ? File.binread(path) : nil, link: File.symlink?(path), sha: raw && self.class.entry(raw, @case)&.fetch("sha256", nil),
        trash: trash }
    end

    def bytes_did(before, after, outcome)
      was = before[:bytes]
      now = after[:bytes]
      changed = if was.nil? && now.nil? then "none"
                elsif now.nil? then "removed"
                elsif was == now && before[:link] == after[:link] then "kept"
                elsif now == @case.incoming then "wrote_incoming"
                else "wrote_other"
                end
      changed += " (link)" if after[:link]
      return changed unless outcome[:refused]

      changed.start_with?("kept", "none") ? "refused" : "#{changed}, then refused"
    end

    def recorded_word(was, after)
      now = after[:sha]
      return "none" if now.nil?
      return "empty" if now.empty?
      return "dev" if Samagotchi::MemoryBundle::Provenance.unchecked?(now)
      return "old" if now == was

      hex = Samagotchi::MemoryBundle::Provenance.recorded_sha(now)
      return "disk" if after[:bytes] && hex == BundleStateCorpus.sha(after[:bytes])
      return "incoming" if @case.incoming && hex == BundleStateCorpus.sha(@case.incoming)

      "other"
    end

    # chi bundle status NAME's line for the file.
    def status_label
      out = StringIO.new
      Samagotchi::BundleCommand.new(["status", NAME], stdout: out, stderr: StringIO.new).run
      return "not installed" if out.string.include?("not installed.")

      # A rule's or script's line under its heading ("Rules (N):",
      # "Scripts (N):"), whole: "r.yml [ok]"; a hook has none ("-").
      prefix = @case.asset == "plugin" ? "  Plugin: " : "    #{File.basename(@case.source_rel)} ["
      line = out.string.lines.map(&:chomp).find { |text| text.start_with?(prefix) }
      return "-" unless line

      @sandbox.mask(@case.asset == "plugin" ? line.delete_prefix(prefix.lstrip).strip : line.strip)
    end

    def names?(line) = line.include?(File.basename(@case.source_rel))

    def run_install = installer(dev: @case.dev?)
    def run_upgrade = installer(upgrade: true)
    def run_upgrade_dry = installer(upgrade: true, dry_run: true)

    def installer(**)
      installer = Samagotchi::MemoryBundle::Installer.new(source: @sandbox.source(@case), name: NAME, strict: true, **)
      refused = begin
        installer.run
        nil
      rescue Samagotchi::MemoryBundle::Installer::InstallError => e
        e.message
      end
      lines = installer.summary.lines.map(&:chomp)
      word_line = lines.find { |line| listed?(line, @case.result_key) }
      word = word_line&.split(": ", 2)&.first
      warns = (lines - [word_line]).select { |line| names?(line) }
      warns << refused if refused
      { word: word, warns: warns.map { |line| @sandbox.mask(line) }.uniq, refused: refused }
    end

    # A "Label: x, y" line listing +name+ (a trailing "(dir)" aside).
    def listed?(line, name)
      label, list = line.split(": ", 2)
      return false unless list && !label.start_with?("Copied to the trash first")

      list.sub(/ \(moved to #{Regexp.escape(@sandbox.root)}.*\)\z/, "")
          .sub(/ \(#{Regexp.escape(@sandbox.root)}.*\)\z/, "").split(", ").include?(name)
    end

    def run_uninstall
      out = StringIO.new
      err = StringIO.new
      status = Samagotchi::BundleCommand.new(["uninstall", NAME], stdout: out, stderr: err).run
      lines = (out.string.lines + err.string.lines).map(&:chomp)
      word_line = lines.find { |line| listed?(line, @case.label) }
      warns = (lines - [word_line]).select { |line| names?(line) || status != 0 }
      { word: word_line&.split(": ", 2)&.first, warns: warns.map { |line| @sandbox.mask(line) }, refused: status != 0 }
    end

    def run_plan
      record = File.join(BundleStateCorpus.bundles_dir, NAME, "manifest.json")
      File.write(record, JSON.pretty_generate(JSON.parse(File.read(record)).merge("source" => SHIPPED_LOOKING)))
      rows = Samagotchi::MemoryBundle::ShippedUpdate.plan(shipped_dir: File.dirname(@sandbox.source(@case)))
      row = rows.find { |candidate| candidate.name == NAME }
      return { word: "no row", warns: [] } unless row

      word = [row.status.to_s, *("replaces" if Array(row.replaced).include?(@case.label))].join(", ")
      { word: word, warns: [row.note].compact.map { |line| @sandbox.mask(line) } }
    end

    def run_status = {}
  end
end

module BundleStateCorpus
  # An asset case's AssetState on its own starting tree (no command run):
  # its file among AssetState.in of its folder, against the case's source or
  # (source: false, as uninstall and status read it) none. asset_state_spec
  # and file_actions_spec read it.
  module AssetStates
    KIND_OF_FILE = { "rule" => :rule, "plugin" => :plugin, "script" => :script }.freeze

    module_function

    # @return [Samagotchi::MemoryBundle::AssetState, nil] nil: no file of that name
    def state(sandbox, kase, shape, source: true)
      run = sandbox.run_copy(kase, shape, "install")
      BundleStateCorpus.at_home(run) do
        provenance = Samagotchi::MemoryBundle::Provenance.new(name: NAME)
        record = provenance.record
        kind = KIND_OF_FILE.fetch(kase.asset)
        dir, recorded = case kind
                        when :rule then [provenance.guardrails_dir, record.guardrails]
                        when :plugin then [provenance.plugin_dir, record.plugin_shas]
                        else [provenance.scripts_dir, record.scripts]
                        end
        name = File.basename(kase.label)
        src = File.join(sandbox.source(kase), kase.source_rel)
        incoming = source && File.file?(src) ? { name => src } : {}
        Samagotchi::MemoryBundle::AssetState.in(dir, kind_of_file: kind, recorded: recorded, incoming: incoming)
                                            .find { |asset| asset.name == name }
      end
    end
  end
end
