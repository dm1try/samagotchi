# frozen_string_literal: true

module AffectedSpecs
  # One spec file picked for a change: its path and why (the changed file
  # and the kind of match).
  Pick = Data.define(:path, :reason)

  # What Picker#pick returns: the Ruby specs and the node tests, best first
  # and uncapped, the hints to print, and the changed code files nothing
  # matched (shown with --why).
  Result = Data.define(:ruby, :node, :hints, :unmatched)

  # Specs that read docs or source as text, or print a file's words through
  # another layer (the REPL golden), which no name points at: a changed path
  # matching one of +match+ (File.fnmatch, ** spans folders) picks +specs+
  # (globs too, matched against the spec files).
  # Keep it short; a rule earns its place when a full run caught what the
  # names missed.
  RULES = [
    { match: %w[docs/configuration.md lib/samagotchi/config.rb],
      specs: %w[spec/docs_configuration_spec.rb], why: "reads docs/configuration.md against Config::ENTRIES" },
    { match: %w[docs/hooks.md lib/samagotchi/tools/builtin_calls.rb],
      specs: %w[spec/docs_hooks_call_fields_spec.rb], why: "reads docs/hooks.md against Tools::BuiltinCalls" },
    { match: %w[lib/samagotchi/events.rb lib/samagotchi/web/public/stream_handlers.js lib/samagotchi/web/public/turn_events.js
                lib/samagotchi/terminal_ui/attached_loop.rb lib/samagotchi/bridge/turn_accumulator.rb],
      specs: %w[spec/events_drift_spec.rb], why: "reads the event handlers' sources against Events" },
    { match: %w[lib/samagotchi/log_line.rb],
      specs: %w[spec/log_spec.rb], why: "checks every Log tag in lib/ against LogLine::TAGS" },
    { match: %w[lib/samagotchi/bundles/system/memory_guide.md],
      specs: %w[spec/tool_declarations_spec.rb], why: "reads the memory guide" },
    { match: %w[lib/samagotchi/bundles/guardrails/**/*],
      specs: %w[spec/guardrails/shipped_bundle_spec.rb spec/guardrails/approvals_spec.rb], why: "reads the shipped guardrails bundle" },
    { match: %w[lib/samagotchi/bundles/*/manifest.yml],
      specs: %w[spec/samagotchi/memory_bundle/shipped_profiles_spec.rb spec/chi_bundle_cli_spec.rb],
      why: "reads shipped manifests for profiles and pins versions in chi bundle CLI" },
    { match: %w[lib/samagotchi/session_metrics.rb spec/fixtures/effective_model/**/*],
      specs: %w[spec/engine_effective_model_characterization_spec.rb], why: "pins effective-model goldens" },
    { match: %w[samagotchi.gemspec],
      specs: %w[spec/gem_contents_spec.rb], why: "builds the gem and lists its files" },
    { match: %w[bin/chi],
      specs: %w[spec/cli_parsing_spec.rb spec/chi_help_spec.rb], why: "runs bin/chi" },
    { match: %w[lib/samagotchi/testing.rb lib/samagotchi/testing/**/* lib/samagotchi/plugin/**/* lib/samagotchi/hooks.rb
                lib/samagotchi/hooks/**/* lib/samagotchi/guardrails/gate.rb],
      specs: %w[lib/samagotchi/bundles/*/spec/**/*_spec.rb],
      why: "the shipped bundles' own specs run on the test kit and chi's plugin and hook seams (they name neither)" },
    { match: %w[lib/samagotchi/turn_flow.rb lib/samagotchi/turn_note.rb],
      specs: %w[spec/terminal_ui_golden_spec.rb], why: "the REPL golden prints their turn-end and continue words" }
  ].freeze

  # A constant named in more spec files than this is a hub: listing them
  # helps no one, the full run covers it.
  HUB_SPECS = 40

  WEB_HINT = "web changed: also run npm run e2e before handing over"

  # Maps changed paths to the spec files a builder should run, in rank
  # order: (1) changed specs, (2) specs named after a changed file,
  # (3) RULES and the goldens of a changed file's layer, (4) weaker name matches (a spec matching more of the changed
  # files first, then one beside the file, see #place), (5) specs naming the
  # changed file's main constant. +tree+ answers spec_files, node_tests,
  # read(path) and mentions(word, paths, word:) (spec path => count).
  class Picker
    # The kind of name match a spec in the changed file's mirrored folder is.
    FOLDER = 2

    def initialize(changed:, tree:)
      @changed = changed.uniq
      @tree = tree
    end

    def pick
      @ruby = {}
      @node = {}
      @hints = []
      @unmatched = []
      @changed.each { |path| add_changed(path) }
      code_files.each { |path| add_strong(path) }
      @changed.each { |path| add_bundle_specs(path) }
      @changed.each { |path| add_rules(path) } # rubocop:disable Style/CombinableLoops -- a tier after the bundle specs
      code_files.each { |path| add_golden(path) }
      # One tier after the other: every golden before any weak name match,
      # every weak name match before any grep hit.
      code_files.each { |path| add_weak(path) } # rubocop:disable Style/CombinableLoops
      add_name_matches
      code_files.each { |path| add_mentions(path) }
      @unmatched = code_files.reject { |path| matched?(path) }
      @hints << WEB_HINT if @changed.any? { |path| web?(path) }
      Result.new(ruby: @ruby.values, node: @node.values, hints: @hints.uniq, unmatched: @unmatched)
    end

    private

    def spec_files = @spec_files ||= @tree.spec_files.sort
    def spec_set = @spec_set ||= spec_files.to_h { |path| [path, true] }
    def node_tests = @node_tests ||= @tree.node_tests.sort

    # Changed files a spec could be named after: Ruby and JS code, spec
    # support files and the shared/fixture data specs read.
    def code_files
      @code_files ||= @changed.select do |path|
        ruby_code?(path) || web_js?(path) || path.start_with?("spec/support/", "spec/shared/", "spec/fixtures/") ||
          (path.start_with?("spec/web/public/") && path.end_with?(".js") && !path.end_with?(".test.js"))
      end
    end

    def ruby_code?(path)
      return true if path == "bin/chi"
      return false unless path.start_with?("lib/", "script/")

      path.end_with?(".rb") || (path.start_with?("script/") && File.extname(path).empty?)
    end

    def web_js?(path) = path.start_with?("lib/samagotchi/web/public/") && path.end_with?(".js") && !path.include?("/vendor/")
    def web?(path) = path.start_with?("lib/samagotchi/web/", "lib/samagotchi/web.rb", "spec/web/public/", "spec/e2e/")

    def add(path, reason, from)
      return unless path

      (@matched ||= {})[from] = true
      if path.end_with?(".test.js")
        @node[path] ||= Pick.new(path: path, reason: reason)
      else
        @ruby[path] ||= Pick.new(path: path, reason: reason)
      end
    end

    def matched?(path) = @matched&.key?(path)

    # 1: a changed spec runs first.
    def add_changed(path)
      add(path, "changed", path) if spec_set.key?(path) || node_tests.include?(path)
    end

    # 2: the spec at the mirrored path, or at the top named after the
    # folders and file (terminal_ui/foo.rb -> terminal_ui_foo_spec.rb).
    def add_strong(path)
      if web_js?(path)
        name = File.basename(path, ".js")
        test = "spec/web/public/#{name}.test.js"
        add(test, "named after #{path}", path) if node_tests.include?(test)
        return
      end
      return if bundle?(path) || !ruby_code?(path)

      parts = name_parts(path)
      rel = parts.join("/")
      candidates = ["spec/#{rel}_spec.rb", "spec/samagotchi/#{rel}_spec.rb", "spec/script/#{parts.last}_spec.rb"]
      candidates += parts.each_index.map { |i| "spec/#{parts[i..].join("_")}_spec.rb" }
      candidates.each { |spec| add(spec, "named after #{path}", path) if spec_set.key?(spec) }
    end

    # 2: any file of a shipped bundle (its plugin, hooks, memories,
    # manifest, its specs' fixtures) picks the bundle's own specs.
    def add_bundle_specs(path)
      bundle = path[%r{\Alib/samagotchi/bundles/([^/]+)/}, 1] or return
      dir = "lib/samagotchi/bundles/#{bundle}/spec/"
      spec_files.each { |spec| add(spec, "the #{bundle} bundle's own spec (#{path})", path) if spec.start_with?(dir) }
    end

    # 3: RULES.
    def add_rules(path)
      RULES.each do |rule|
        next unless rule[:match].any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME) }

        rule[:specs].each do |pattern|
          spec_files.each do |spec|
            add(spec, "rule: #{rule[:why]} (#{path})", path) if File.fnmatch?(pattern, spec, File::FNM_PATHNAME)
          end
        end
      end
    end

    # 3, after the rules: a golden spec renders a whole layer, so any file
    # in its folder picks it (terminal_ui.rb, terminal_ui/status_row.rb ->
    # spec/terminal_ui_golden_spec.rb); no name points at it otherwise.
    def add_golden(path)
      return if bundle?(path) || !ruby_code?(path) || path.start_with?("script/")

      parts = name_parts(path)
      parts.each_index do |i|
        layer = parts[0..i].join("_")
        spec = "spec/#{layer}_golden_spec.rb"
        add(spec, "golden of #{layer} (#{path})", path) if spec_set.key?(spec)
      end
    end

    # 4: a bundle's specs by its name; a node test importing the changed
    # web file; a spec naming a support or data file; a dev script's spec
    # folder. A code file's name matches are #add_name_matches.
    def add_weak(path)
      if web_js?(path) || path.start_with?("spec/web/public/")
        name = File.basename(path)
        @tree.mentions("/#{name}", node_tests).each_key { |test| add(test, "imports #{path}", path) unless test == path }
        return
      end
      if path.start_with?("spec/support/", "spec/shared/", "spec/fixtures/")
        add_data_users(path)
        return
      end
      return unless ruby_code?(path) || bundle?(path)

      if bundle?(path)
        bundle = path.split("/")[3].tr("-", "_").split("_")
        spec_files.each { |spec| add(spec, "names bundle #{path.split("/")[3]}", path) if contains?(tokens(spec), bundle) }
        return
      end
      return unless path.start_with?("script/")

      # A dev script's specs live in a folder named after it.
      dir = "spec/#{name_parts(path).first}/"
      spec_files.each { |spec| add(spec, "in spec folder of #{path}", path) if spec.start_with?(dir) }
    end

    # 4, for the code files: the same file name anywhere, a spec whose name
    # starts with or contains it (foo_bar.rb -> foo_bar_x_spec.rb,
    # x_foo_bar_spec.rb), the specs in the file's mirrored folder. Ranked
    # over all the changed files at once: a spec that matches more of them
    # first (engine.rb + toolkit.rb -> engine_toolkit_spec.rb), then by
    # #place, then by the kind of match, then in the changed files' order.
    def add_name_matches
      found = Hash.new { |hash, spec| hash[spec] = [] }
      code_files.each_with_index do |path, index|
        next unless ruby_code?(path) && !bundle?(path) && !path.start_with?("script/")

        name_candidates(path).each { |spec, kind| found[spec] << [path, place(spec, path), kind, index] }
      end
      ranked = found.map do |spec, hits|
        hits = hits.uniq(&:first)
        # A match counts toward "more of the changed files" only beside the
        # file: plugin/context.rb's name in engine_context_note_spec.rb is
        # another context.
        near = hits.count { |path, place, *| place.zero? || (place == 1 && name_parts(path).size == 1) }
        [near, hits.min_by { |hit| hit.drop(1) }, hits, spec]
      end
      ranked.sort_by { |size, best, _, spec| [-size, *best.drop(1), spec] }.each do |_, best, hits, spec|
        reason = best[2] == FOLDER ? "in spec folder of #{best[0]}" : "name matches #{best[0]}"
        others = hits.map(&:first) - [best[0]]
        reason += " (and #{others.join(", ")})" if others.any?
        add(spec, reason, best[0])
        others.each { |path| (@matched ||= {})[path] = true }
      end
    end

    # { spec => kind } for a code file's name: 0 the same name, 1 a name
    # starting with it, FOLDER a spec in the file's mirrored folder, 3 a
    # name containing it.
    def name_candidates(path)
      parts = name_parts(path)
      base = parts.last.split("_")
      dir = "spec/#{parts.join("/")}/"
      spec_files.each_with_object({}) do |spec, kinds|
        t = tokens(spec)
        kind = if t == base then 0
               elsif t.first(base.size) == base then 1
               elsif spec.start_with?(dir) then FOLDER
               elsif contains?(t, base) then 3
               end
        kinds[spec] = kind if kind
      end
    end

    # How near +spec+ sits to the changed file: 0 beside it (its mirrored
    # folder, spec/ or spec/samagotchi/, or a top-level spec named with
    # that folder: plugin/context.rb -> spec/samagotchi/plugin/,
    # spec/plugin_context_x_spec.rb), 1 a top-level spec, 2 a spec in
    # another folder (spec/guardrails/context_spec.rb for plugin/context.rb:
    # another file of that name).
    def place(spec, path)
      parts = name_parts(path)
      dirs = parts[0...-1]
      folder = spec_folder(spec)
      if folder.any?
        beside = (dirs.any? && folder.first(dirs.size) == dirs) || folder.first(parts.size) == parts
        return beside ? 0 : 2
      end
      prefix = dirs.join("_").split("_")
      dirs.any? && tokens(spec).first(prefix.size) == prefix ? 0 : 1
    end

    # spec/samagotchi/plugin/x_spec.rb -> ["plugin"]; spec/x_spec.rb -> [].
    def spec_folder(spec) = spec.delete_prefix("spec/").delete_prefix("samagotchi/").split("/")[0...-1]

    def add_data_users(path)
      key = if path.start_with?("spec/support/")
              "support/#{File.basename(path, ".rb")}"
            elsif path.start_with?("spec/fixtures/")
              path.split("/")[2].sub(/\.[^.]+\z/, "")
            else
              File.basename(path)
            end
      @tree.mentions(key, spec_files + node_tests).keys.sort.each { |spec| add(spec, "uses #{path}", path) unless spec == path }
    end

    # 5: specs naming the file's main constant, most mentions first; a
    # constant in more than HUB_SPECS spec files gets a hint instead.
    def add_mentions(path)
      return unless ruby_code?(path) && !bundle?(path)

      constant = main_constant(path)
      return unless constant

      hits = @tree.mentions(constant, spec_files, word: true)
      if hits.size > HUB_SPECS
        @hints << "hub: #{constant} (#{path}) is named in #{hits.size} spec files; the full run covers it"
        return
      end
      hits.sort_by { |spec, count| [-count, spec] }.each { |spec, _| add(spec, "names #{constant} (#{path})", path) }
    end

    # The class or module the file is named after (foo_bar.rb -> FooBar,
    # also LLM/UI spellings), read from the file. A short name (CLI, Log)
    # comes with its parent (AffectedSpecs::CLI), or it names half the suite.
    def main_constant(path)
      source = @tree.read(path)
      return unless source

      want = File.basename(path, ".rb").delete("_-").downcase
      stack = []
      source.each_line do |line|
        next unless (m = line.match(/^(\s*)(?:class|module)\s+((?:\w+::)*\w+)/))

        stack.pop while stack.any? && stack.last[0] >= m[1].size
        stack << [m[1].size, m[2]]
        next unless m[2].split("::").last.downcase == want

        name = m[2].split("::").last
        return name if name.size >= 5

        parent = m[2].include?("::") ? m[2].split("::")[-2] : stack[-2]&.last&.split("::")&.last
        return parent && parent != "Samagotchi" ? "#{parent}::#{name}" : name
      end
      nil
    end

    def bundle?(path) = path.start_with?("lib/samagotchi/bundles/")

    # lib/samagotchi/a/b.rb -> ["a", "b"]; script/x-y -> ["x_y"].
    def name_parts(path)
      rel = path.delete_prefix("lib/samagotchi/").sub(%r{\A(lib|script|bin)/}, "").delete_suffix(".rb")
      rel.tr("-", "_").split("/")
    end

    def tokens(spec) = File.basename(spec, "_spec.rb").split("_")

    def contains?(haystack, needle)
      return false if needle.empty? || needle.size > haystack.size

      (0..(haystack.size - needle.size)).any? { |i| haystack[i, needle.size] == needle }
    end
  end
end
