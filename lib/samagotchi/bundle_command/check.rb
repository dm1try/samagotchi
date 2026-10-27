# frozen_string_literal: true

require "prism"
require "rbconfig"
require "stringio"
require "tmpdir"
require_relative "../memory_bundle"
require_relative "../memory_bundle/shas"
require_relative "../memory_bundle/memory_files"
require_relative "../plugin/api"
require_relative "../version"
require_relative "../cli/flags"

module Samagotchi
  class BundleCommand
    # `chi bundle check [PATH] [--fix] [--set KEY=VALUE]`: what keeps the
    # bundle at PATH from installing and loading cleanly, one finding per
    # line (docs/cli.md):
    #
    #   error|warn|info CODE file[:line]: message (fix: hint)
    #
    # It installs and loads the bundle in a Testing::Sandbox (temp HOME and
    # XDG dirs), not in the user's config or state, but in this process: the
    # plugin's and hooks' own code runs as written; --fix rewrites stale
    # sha256 lines (MemoryBundle::Shas). #run returns 0 without errors, 1
    # with any.
    class Check
      HELP = <<~TEXT
        Usage: chi bundle check [PATH] [--fix] [--set KEY=VALUE]

          Check the bundle at PATH (default: .) as an install would take it, one finding per line:
            error|warn|info CODE file[:line]: message (fix: hint)
          It installs and loads the bundle in a sandbox (temp HOME, config and state), not in yours, but its plugin and
          hooks run in this process as written: run it on code you'd install.
          --fix            rewrite stale and placeholder sha256 lines in manifest.yml
          --set KEY=VALUE  a setting for the load (config.yml bundles: <name>: KEY), repeatable
          Exit status: 0 no errors, 1 errors, 2 usage.
      TEXT
      FLAGS = CLI::Flags.new(help: %w[--help], flag_pattern: /\A--/) do |f|
        f.switch "--fix"
        f.value "--set", key: :set, repeat: true
      end

      Finding = Data.define(:level, :code, :file, :line, :message, :fix) do
        def error? = level == :error

        def to_s
          where = line ? "#{file}:#{line}" : file
          "#{level} #{code} #{where}: #{message}#{" (fix: #{fix})" if fix}"
        end
      end

      LIB_DIR = File.expand_path("../..", __dir__)
      TRUSTED = %w[reviewed trusted].freeze
      # A call of the plugin API (with one member after it: ctx.sessions.children),
      # or a name SINCE lists, in the source.
      API_CALL = /\b(?:chi|ctx)\.[a-z_]+(?:\.[a-z_]+)?\b|\bfallback_for:|\bSamagotchi::AtomicFile\b/
      # A requirement's lower bound: >= X, > X, ~> X or = X.
      LOWER_BOUND = /\A(?:>=|>|~>|=)?\s*(\d+(?:\.\d+)*)\z/

      # @param dir [String] the bundle's folder
      # @param fix [Boolean] rewrite stale sha lines
      # @param settings [Hash] config.yml `bundles: <name>:` for the load
      def initialize(dir, fix: false, settings: {}, stdout: $stdout)
        @dir = File.expand_path(dir)
        @fix = fix
        @settings = settings
        @stdout = stdout
        @findings = []
      end

      # @return [Integer] exit status
      def run
        manifest = read_manifest
        if manifest
          missing = check_files(manifest)
          check_unlisted(manifest)
          check_shas unless missing
          check_requires_chi(manifest)
          check_trust(manifest)
          check_clash(manifest)
          check_install(manifest) unless missing || placeholders? || manifest.session_settings_clash
          check_boundary(manifest)
          check_tests
        end
        errors = @findings.count(&:error?)
        warnings = @findings.count { |f| f.level == :warn }
        @stdout.puts "#{errors.zero? ? "ok" : "failed"}: #{errors} error#{"s" unless errors == 1}, " \
                     "#{warnings} warning#{"s" unless warnings == 1} (#{display(@dir)})"
        errors.zero? ? CLI::Exit::OK : CLI::Exit::FAILED
      end

      private

      def add(level, code, file, message, line: nil, fix: nil)
        finding = Finding.new(level: level, code: code, file: file, line: line, message: message, fix: fix)
        @findings << finding
        @stdout.puts finding
      end

      def path(rel) = File.join(@dir, rel)

      def display(dir) = dir.start_with?("#{Dir.pwd}/") ? dir.delete_prefix("#{Dir.pwd}/") : dir

      # Through symlinks on both sides: a linked path to chi's own bundle is it.
      def shipped? = File.dirname(File.realpath(@dir)) == File.realpath(MemoryBundle::SourceNormalizer::SHIPPED_DIR)

      # ── manifest ──────────────────────────────────────────────────────

      # The manifest, parsed with its placeholder shas taken (a stale sha is
      # check_shas' finding, not a parse error); nil after a `manifest` error.
      def read_manifest
        unless File.file?(path("manifest.yml"))
          add(:error, :manifest, "manifest.yml", "no manifest.yml in #{display(@dir)}", fix: "chi bundle new NAME")
          return nil
        end

        @text = File.read(path("manifest.yml"))
        Dir.mktmpdir("chi-bundle-check-") do |tmp|
          File.write(File.join(tmp, "manifest.yml"), MemoryBundle::Shas.parseable(@text))
          MemoryBundle::Manifest.read(dir: tmp)
        rescue MemoryBundle::Manifest::ValidationError => e
          add(:error, :manifest, "manifest.yml", e.message.gsub(tmp, display(@dir)))
          nil
        end
      end

      # The line of manifest.yml naming +file+ (its entry), or nil.
      def manifest_line(file)
        base = File.basename(file)
        index = @text.lines.index { |l| l.match?(/\A\s*(?:file: )?["']?#{Regexp.escape(base)}["']?:?(?:\s|\z)/) }
        index && (index + 1)
      end

      # ── files ─────────────────────────────────────────────────────────

      # @return [Boolean] whether a listed file is missing
      def check_files(manifest)
        listed = manifest.files.keys + Array(manifest.plugin && manifest.plugin[:file]) +
                 manifest.hooks.keys.map { |h| File.join("hooks", h) } + manifest.scripts.keys.map { |s| File.join("scripts", s) }
        missing = listed.reject { |rel| File.file?(path(rel)) }
        missing.each do |rel|
          add(:error, :"missing-file", "manifest.yml", "lists #{rel}, which isn't in the bundle", line: manifest_line(rel),
                                                                                                fix: "add the file or drop the entry")
        end
        !missing.empty?
      end

      # What an install leaves out: a memory files: doesn't list (by
      # MemoryFiles' rules), a plugin, hook or script the manifest doesn't name.
      def check_unlisted(manifest)
        memories = MemoryBundle::MemoryFiles.select(@dir, manifest)
        loose = Dir.glob(path("*.md")).map { |f| File.basename(f) }.sort.reject do |name|
          memories.include?(name) || MemoryBundle::MemoryFiles.repo_meta?(name)
        end
        loose.each { |name| unlisted(name, "files:") }
        plugin = manifest.plugin && manifest.plugin[:file]
        unlisted("plugin.rb", "plugin:") if File.file?(path("plugin.rb")) && plugin != "plugin.rb"
        Dir.glob(path("hooks/*.rb")).sort.each do |file|
          unlisted("hooks/#{File.basename(file)}", "hooks:") unless manifest.hooks.key?(File.basename(file))
        end
        Dir.glob(path("scripts/*")).sort.each do |file|
          unlisted("scripts/#{File.basename(file)}", "scripts:") unless manifest.scripts.key?(File.basename(file))
        end
      end

      def unlisted(rel, key)
        add(:warn, :unlisted, rel, "manifest.yml's #{key} doesn't list it, so an install leaves it out",
            fix: "list it under #{key}, then chi bundle check --fix")
      end

      # ── sha256 lines ──────────────────────────────────────────────────

      def check_shas
        if @fix
          text, changes = MemoryBundle::Shas.refresh(@dir, @text)
          unless changes.empty?
            File.write(path("manifest.yml"), text)
            @text = text
            changes.each { |file, _old, new| @stdout.puts "fixed sha #{file} → sha256:#{new[0, 12]}…" }
          end
        end
        MemoryBundle::Shas.stale(@dir, @text).each do |stale|
          line = manifest_line(stale.file)
          if stale.old.nil?
            add(:error, :sha, "manifest.yml", "#{stale.file} has no sha256 line, so it installs unchecked", line: line,
                                                                                                          fix: "add `sha256: sha256:` under its entry, then chi bundle check --fix")
          else
            what = stale.old.empty? ? "a placeholder sha256" : "a stale sha256"
            add(:error, :sha, "manifest.yml", "#{what} for #{stale.file}", line: line, fix: "chi bundle check --fix")
          end
        end
      rescue MemoryBundle::Shas::Error => e
        add(:error, :sha, "manifest.yml", e.message.sub(%r{\A[^/]+/manifest\.yml:? ?}, ""))
      end

      # ── requires_chi ──────────────────────────────────────────────────

      def code?(manifest) = manifest.plugin || manifest.hooks.any? || manifest.scripts.any?

      def check_requires_chi(manifest)
        line = manifest_line("requires_chi")
        if (failure = MemoryBundle::Manifest.requires_chi_failure(manifest.requires_chi, VERSION))
          @too_new = true
          add(:error, :"requires-chi", "manifest.yml", "this chi can't load it: #{failure}", line: line,
                                                                                            fix: "chi update, or lower requires_chi")
        elsif manifest.requires_chi.nil? && code?(manifest)
          add(:warn, :"requires-chi", "manifest.yml", "no requires_chi for a bundle with code", fix: "add requires_chi: \">= #{VERSION}\"")
        end
        check_floor(manifest, line) if manifest.plugin && manifest.requires_chi && !@too_new
      end

      # The plugin calls an API newer than the oldest chi requires_chi admits.
      def check_floor(manifest, line)
        floor = lower_bound(manifest.requires_chi)
        return unless floor && File.file?(path(manifest.plugin[:file]))

        source = File.read(path(manifest.plugin[:file]))
        calls = source.scan(API_CALL).flat_map { |call| [call, call.split(".").first(2).join(".")] }
        calls = (calls + keyword_calls(source)).uniq.select { |call| Plugin::Api::SINCE.key?(call) }
        call = calls.max_by { |c| Gem::Version.new(Plugin::Api::SINCE[c]) } or return
        version = Plugin::Api::SINCE[call]
        return unless Gem::Version.new(version) > floor

        add(:warn, :"requires-chi-floor", "manifest.yml",
            "requires_chi #{manifest.requires_chi.inspect} admits chi #{floor}, but #{manifest.plugin[:file]} uses " \
            "#{call}, which needs chi #{version}", line: line,
                                                                                      fix: "requires_chi: \">= #{version}\"")
      end

      # Each API call's keywords in +source+, as "chi.toolkit(groups:)": the
      # call's receiver as written, its name and the keyword (Prism sees
      # them with or without parens, over lines). Nothing when it doesn't parse.
      def keyword_calls(source)
        result = Prism.parse(source)
        return [] unless result.success?

        found = []
        nodes = [result.value]
        while (node = nodes.pop)
          nodes.concat(node.compact_child_nodes)
          next unless node.is_a?(Prism::CallNode) && node.receiver && node.arguments

          call = "#{node.receiver.slice}.#{node.name}"
          node.arguments.arguments.grep(Prism::KeywordHashNode).each do |hash|
            hash.elements.each do |pair|
              found << "#{call}(#{pair.key.unescaped}:)" if pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode)
            end
          end
        end
        found
      end

      def lower_bound(requirement)
        requirement.to_s.split(",").filter_map do |part|
          version = part.strip[LOWER_BOUND, 1]
          Gem::Version.new(version) if version
        end.max
      end

      def check_trust(manifest)
        return if shipped? || !TRUSTED.include?(manifest.trust_level)

        add(:warn, :trust, "manifest.yml", "trust_level: #{manifest.trust_level} is set by the bundle's author",
            line: manifest_line("trust_level"), fix: "leave it out unless someone reviewed the bundle")
      end

      # ── install and load ──────────────────────────────────────────────

      # Before the sandbox: the user's installed bundles and chi's shipped ones.
      def check_clash(manifest)
        name = manifest.name
        # A session setting --set would read as chi's own: the install refuses it.
        if (clash = manifest.session_settings_clash)
          add(:error, :clash, "manifest.yml", clash, line: manifest_line("session_settings"))
        end
        shipped = MemoryBundle::Listing.shipped.map(&:name) + [MemoryBundle::SystemBundle::BUNDLE_NAME]
        if shipped.include?(name) && !shipped?
          add(:warn, :clash, "manifest.yml", "chi ships a bundle named #{name}; installing this one replaces chi's",
              line: manifest_line("name"), fix: "rename the bundle")
        end
        # A shipped bundle installed from any chi's copy is that bundle.
        return if shipped?

        record = installed_record(name)
        return unless record
        return unreadable_clash(name, record.error) if record.error
        return if File.expand_path(record.source.to_s) == @dir

        add(:warn, :clash, "manifest.yml", "a bundle named #{name} is installed from #{record.source}",
            line: manifest_line("name"), fix: "rename the bundle, or chi bundle upgrade #{display(@dir)} to replace it")
      end

      # The installed same-named bundle's record; an unreadable one as
      # InstalledBundle.unreadable.
      def installed_record(name)
        MemoryBundle::Provenance.new(name: name).record
      rescue JSON::ParserError, SystemCallError => e
        MemoryBundle::InstalledBundle.unreadable(name, "#{e.class}: #{e.message.lines.first&.strip}")
      end

      def unreadable_clash(name, error)
        add(:warn, :clash, "manifest.yml", "a bundle named #{name} is installed, but its record can't be read (#{error})",
            line: manifest_line("name"), fix: "rename the bundle, or chi bundle install --force #{display(@dir)} to replace it")
      end

      # An unfilled `sha256: sha256:` isn't YAML: the Installer can't read
      # the manifest until --fix fills it.
      def placeholders?
        return false unless @findings.any? { |f| f.code == :sha && f.message.start_with?("a placeholder") }

        add(:info, :install, "manifest.yml", "skipped until the placeholder shas are filled", fix: "chi bundle check --fix")
        true
      end

      def check_install(manifest)
        require_relative "../testing"
        result = nil
        # The log's echoes (the "experimental" line every external bundle
        # gets) are left out: what failed is in the result.
        quietly do
          Testing::Sandbox.with do |sandbox|
            result = Testing::Install.run(@dir, settings: @settings, sandbox: sandbox, force: true)
          end
        end
        install_warnings(result.warnings)
        # The loaders refuse a bundle requires_chi rules out: that's the requires-chi error.
        result.failures.each { |failure| install_failure(failure) unless @too_new && failure.reason.include?("it requires chi") }
        report_registered(manifest, result.registered)
      rescue MemoryBundle::Installer::InstallError, MemoryBundle::Manifest::ValidationError => e
        add(:error, :install, "manifest.yml", e.message)
      rescue StandardError => e
        # Whatever else the install or the load raised: one finding, not a trace.
        add(:error, :install, "manifest.yml", "the sandboxed install failed: #{e.class}: #{e.message}")
      end

      def quietly
        saved = $stderr
        $stderr = StringIO.new
        yield
      ensure
        $stderr = saved
      end

      def install_warnings(warnings)
        stale_reported = @findings.any? { |f| f.code == :sha }
        warnings.each do |warning|
          next if stale_reported && warning.start_with?("Checksum mismatch")
          next if @too_new && warning.include?("won't load:")

          if warning.start_with?("needs ")
            add(:warn, :install, "manifest.yml", warning)
          else
            add(:error, :install, "manifest.yml", warning)
          end
        end
      end

      def install_failure(failure)
        file, line = failure.location&.match(/\A(.+):(\d+)\z/)&.captures
        file = file ? file.delete_prefix("#{@dir}/") : "manifest.yml"
        add(:error, :install, file, "#{failure.what} failed to load: #{failure.reason}", line: line&.to_i)
      end

      def report_registered(manifest, registered)
        plugin = manifest.plugin ? manifest.plugin[:file] : "manifest.yml"
        registered.commands.each { |command| add(:info, :registered, plugin, "command #{command.name}") }
        registered.tools.each { |name| add(:info, :registered, plugin, "tool #{name}") }
        registered.hooks.each do |event, hooks|
          hooks.each do |hook|
            file = manifest.hooks.key?(hook.hook) ? "hooks/#{hook.hook}" : plugin
            next add(:info, :registered, file, "hook #{event} (priority #{hook.priority})") if Hooks::EVENTS.include?(event)

            add(:warn, :"hook-event", file, "hook on #{event.inspect}, which chi never fires",
                fix: "one of #{Hooks::EVENTS.join(", ")}")
          end
        end
        { "init" => registered.inits, "toolkit" => registered.toolkits, "tool source" => registered.tool_sources,
          "peer source" => registered.peer_sources }.each do |what, names|
          names.each { |name| add(:info, :registered, plugin, "#{what} #{name}") }
        end
      end

      # ── what it reaches of chi ────────────────────────────────────────

      def check_boundary(manifest)
        require_relative "../testing/boundary"
        known = shipped? ? Testing::Boundary::EXCEPTIONS.fetch(manifest.name, {}) : {}
        Testing::Boundary.scan(@dir).reject { |f| known.key?(f.reference) }.each do |finding|
          add(:warn, :boundary, finding.file, "#{finding.reference} is internal to chi and may break on a chi upgrade",
              fix: "use chi.* / ctx, or the names docs/plugins.md lists as stable")
        end
      end

      # ── tests ─────────────────────────────────────────────────────────

      def check_tests
        tests = Dir.glob(path("test/**/*_test.rb")).sort.map { |f| f.delete_prefix("#{@dir}/") }
        if tests.any?
          add(:info, :tests, "test/", "#{tests.size} file#{"s" unless tests.size == 1}: run chi bundle test " \
                                      "(Minitest on #{RbConfig.ruby}, -I #{LIB_DIR})")
        elsif File.directory?(path("spec"))
          add(:info, :tests, "spec/", "chi bundle test (runs rspec with the kit)")
        else
          add(:info, :tests, display(@dir), "no tests", fix: "chi bundle new NAME writes one to copy")
        end
      end
    end
  end
end
