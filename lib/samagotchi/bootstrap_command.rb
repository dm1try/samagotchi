# frozen_string_literal: true

require "rbconfig"
require_relative "config"
require_relative "model_profile"
require_relative "host_registry"
require_relative "bootstrap/probe"
require_relative "bootstrap/config_writer"
require_relative "bootstrap/bundles"
require_relative "cli/command"
require_relative "cli/flags"

module Samagotchi
  # `chi bootstrap [TARGET]`: the first setup. It names a model server, works
  # out what it is (llama.cpp's native API or an OpenAI-compatible one),
  # picks the model, sends one test request and writes config.yml: a fresh
  # file, or a hosts: entry added to an existing one. Then it installs the
  # system bundle and the core profile, and on a terminal asks about dev.
  # Prompts only on a terminal; a script gets the list and exit 2 instead.
  class BootstrapCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi bootstrap [TARGET] [--name NAME] [--model ID] [--key-env VAR] [--no-test] [--dry-run]
        Finds the model server at TARGET and writes config.yml for it.
          chi bootstrap 192.168.1.29:8081          llama.cpp on the LAN
          chi bootstrap localhost:11434            Ollama
          chi bootstrap https://openrouter.ai/api/v1 --key-env OPENROUTER_API_KEY
          chi bootstrap                            look on this machine's usual ports
        TARGET        host[:port] (port 8080 when none), or a URL; a URL's
                      path is the OpenAI API base
        --name NAME   the hosts entry's name (default: local, lan, or the
                      domain's name)
        --model ID    the model, when the server has several
        --key-env VAR the environment variable holding the API key (the
                      key itself is never written)
        --no-test     skip the test request
        --dry-run     show what would be written; write nothing
        With no config.yml it writes one; an existing one gets a hosts:
        entry added (after a backup), and its other lines stay as they are.
        Then it installs the system bundle and the core bundles (loop-guard,
        check-in, guardrails), and on a terminal offers the dev bundles.
    TEXT

    FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS) do |f|
      f.value "--name"
      f.value "--model"
      f.value "--key-env"
      f.switch "--no-test"
      f.switch "--dry-run"
    end

    PICK_SHOWN = 20
    # A test request slower than this says it is waiting (a model loading).
    LOADING_AFTER = 3
    # The profile bootstrap installs, and the one it offers on a terminal.
    CORE = "core"
    DEV = "dev"
    # The config outcomes after which the bundles are installed.
    INSTALLS_BUNDLES = %i[new appended exists snippet].freeze

    # @param argv [Array<String>] the arguments after "bootstrap"
    # @param probe [Bootstrap::Probe, nil] (specs)
    # @param bundles [Bootstrap::Bundles, nil] (specs: the bundles go where
    #   the process ENV points, not +env+)
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, env: ENV, probe: nil, config_path: nil,
                   platform: RbConfig::CONFIG["host_os"], bundles: nil)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @env = env
      @probe = probe || Bootstrap::Probe.new(env: env)
      @config_path = config_path || ConfigFile.global_path(env: env)
      @platform = platform
      @bundles = bundles || Bootstrap::Bundles.new
    end

    # @return [Integer] 0 written (or already there), 1 failed (a failed
    #   test still writes the config), 2 usage or a choice to make
    def run
      options = parse
      return options if options.is_a?(Integer)

      key_env = options[:key_env]
      return fail!("#{key_env} is not set; export it first (the API key; chi only writes its name)") if key_env && unset?(key_env)

      result = find(options, key_env) or return @exit
      unlocked = with_key(result, key_env) or return @exit
      result, key_env = unlocked
      describe(result)
      model = pick_model(result, options[:model]) or return @exit
      show_model(result, model, key_env)
      tested = options[:no_test] || test(result, model, key_env)
      written = write(result, model, key_env, options) or return @exit
      written.zero? && tested ? 0 : 1
    end

    private

    def command_name = "chi bootstrap"
    # A usage error's line ends with "(see chi bootstrap --help)".
    def usage_on_error = nil

    # @return [Hash, Integer] the options, or the exit status after the
    #   help or a usage error
    def parse
      parsed = parse_flags(FLAGS, @argv)
      return parsed if parsed.is_a?(Integer)

      options = parsed.options
      target, extra = parsed.args
      return usage_error("one TARGET only (got #{target} and #{extra})") if extra

      options[:target] = target if target
      if options[:key_env] && !options[:key_env].match?(ConfigFile::ENV_NAME_RE)
        return usage_error("--key-env takes the variable's name (e.g. OPENROUTER_API_KEY), not the key")
      end

      options
    end

    # The server's Probe::Result, or nil with @exit set.
    def find(options, key_env)
      return scan unless options[:target]

      candidates = begin
        Bootstrap::Probe.candidates(options[:target])
      rescue ArgumentError => e
        @exit = usage_error(e.message)
        return nil
      end
      result = @probe.classify_target(candidates, key_env: key_env)
      case result.kind
      when :unreachable
        fail!("can't reach #{result.candidate.label} (#{result.reason})")
      when :unknown
        detail = result.status ? "HTTP #{result.status}" : result.reason
        fail!("reached #{result.candidate.label} but it answers neither llama.cpp /props nor /v1/models (#{detail})")
      else result
      end
    end

    def scan
      found = @probe.scan_local
      ports = Bootstrap::Probe::LOCAL_PORTS.keys.join(", ")
      return fail!("no model server found on localhost (#{ports}); pass one: chi bootstrap HOST[:PORT]") if found.empty?
      return found.first if found.size == 1

      labels = found.map { |r| "#{r.candidate.label} (#{Bootstrap::Probe::LOCAL_PORTS[r.candidate.port]}, #{models_count(r)})" }
      unless tty?
        @stderr.puts("chi bootstrap: model servers on this machine:")
        labels.each { |label| @stderr.puts("  #{label}") }
        @stderr.puts("pick one: chi bootstrap localhost:PORT")
        @exit = 2
        return nil
      end
      picked = pick(labels, "server") or return fail!("nothing picked")
      found[labels.index(picked)]
    end

    def models_count(result)
      n = result.models.size
      n == 1 ? "1 model" : "#{n} models"
    end

    # [result, key_env] once the server lets us in, or nil with @exit set.
    def with_key(result, key_env)
      return [result, key_env] unless result.kind == :needs_key

      host = result.candidate.label
      return fail!("#{host} refused the key in #{key_env} (HTTP #{result.status})") if key_env

      unless tty?
        @stderr.puts("chi bootstrap: #{host} wants an API key (HTTP #{result.status}); " \
                     "pass the variable that holds it: --key-env VAR")
        @exit = 2
        return nil
      end
      @stdout.print("#{host} wants an API key. API key environment variable (e.g. OPENROUTER_API_KEY): ")
      key_env = @stdin.gets.to_s.strip
      return fail!("no variable given") if key_env.empty?
      return fail!("#{key_env} isn't a variable name") unless key_env.match?(ConfigFile::ENV_NAME_RE)
      return fail!("#{key_env} is not set; export it and run chi bootstrap again") if unset?(key_env)

      result = @probe.classify(result.candidate, key_env: key_env)
      return fail!("#{host} refused the key in #{key_env} (HTTP #{result.status})") if result.kind == :needs_key
      return fail!("can't reach #{host} (#{result.reason || "HTTP #{result.status}"})") unless result.reached?

      [result, key_env]
    end

    def describe(result)
      if result.native?
        build = result.props["build_info"].to_s
        @stdout.puts("found: llama.cpp at #{result.candidate.root}#{build.empty? ? "" : " (build #{build})"}")
      else
        @stdout.puts("found: an OpenAI-compatible API at #{result.candidate.base}")
      end
    end

    def pick_model(result, wanted)
      ids = result.models.map(&:id).reject(&:empty?)
      if wanted
        return wanted if ids.empty?

        match = ids.find { |id| id == wanted } || ids.find { |id| id.casecmp?(wanted) }
        return match if match

        @stderr.puts("chi bootstrap: #{result.candidate.label} has no model #{wanted}; it lists:")
        ids.each { |id| @stderr.puts("  #{id}") }
        @exit = 1
        return nil
      end
      return fail!("#{result.candidate.label} lists no models; pass one: --model ID") if ids.empty?
      return ids.first if ids.size == 1
      return pick(ids, "model") || fail!("nothing picked") if tty?

      @stderr.puts("chi bootstrap: #{result.candidate.label} has #{ids.size} models:")
      ids.each { |id| @stderr.puts("  #{id}") }
      @stderr.puts("pick one: --model ID")
      @exit = 2
      nil
    end

    def show_model(result, model, key_env)
      @stdout.puts("model: #{model}")
      return unless result.native?

      props = @probe.model_props(result.candidate, model, key_env: key_env) || result.props
      n_ctx = props.dig("default_generation_settings", "n_ctx")
      @stdout.puts("context: #{n_ctx} tokens") if n_ctx.is_a?(Integer) && n_ctx.positive?
      profile, evidence = ModelProfile.fingerprint(props)
      @stdout.puts("profile: #{profile} (chat template: #{evidence})") if profile
    end

    def test(result, model, key_env)
      done = Queue.new
      waiting = if loading_hint?(result)
                  Thread.new do
                    @stdout.puts("test: waiting for an answer (loading the model?)…") if done.pop(timeout: LOADING_AFTER).nil?
                  end
                end
      seconds = @probe.test_turn(result.candidate, model, key_env: key_env)
      @stdout.puts(format("test: answered in %.1f s", seconds))
      true
    rescue StandardError => e
      @stdout.puts("test: failed: #{e.message}")
      false
    ensure
      done&.push(true)
      waiting&.join
    end

    # The "loading the model?" hint fits a local server (a llama.cpp loading
    # weights); a remote provider's slow answer is the network, not a load.
    def loading_hint?(result)
      !HostRegistry.remote_address?(result.candidate.scheme, result.candidate.host)
    end

    # 0 written, 1 written but not as planned, nil with @exit on a refusal.
    def write(result, model, key_env, options)
      writer = Bootstrap::ConfigWriter.new(path: @config_path, env: @env)
      fields = host_fields(result.candidate, result.native?, key_env)
      ids = result.models.map(&:id)
      base = Bootstrap::ConfigWriter.derived_name(result.candidate.host)
      name, reason = begin
        writer.host_name_with_reason(base, requested: options[:name], model_ids: ids)
      rescue Bootstrap::ConfigWriter::Error => e
        @exit = usage_error(e.message)
        return nil
      end
      explain_name(base, name, reason)
      outcome = writer.write(name: name, fields: fields, model: model, dry_run: options[:dry_run])
      code = report(outcome, model)
      return code unless INSTALLS_BUNDLES.include?(outcome.kind)

      code = [code, install_bundles].max
      next_steps if outcome.kind == :new
      code
    end

    # One line when the name wasn't free as derived: why chi picked another.
    def explain_name(base, name, reason)
      case reason
      when :taken
        @stdout.puts("a host named #{base} already exists; saved as #{name}, use --name to choose")
      when :model_prefix
        @stdout.puts("a model id starts with #{base} (chi would read it as a host); saved as #{name}, use --name to choose")
      end
    end

    # The system bundle, core, and dev when a terminal says yes: one line
    # each. 1 when something failed.
    def install_bundles(dry_run: false)
      ok = system_bundle_line(@bundles.sync_system(dry_run: dry_run), dry_run)
      ok = install_profile(CORE, dry_run) && ok
      unless dry_run || !tty? || (members = dev_to_install).empty?
        @stdout.print("Also install #{DEV} (#{members.join(", ")})? [y/N] ")
        ok = install_profile(DEV, false) && ok if @stdin.gets.to_s.strip.downcase.start_with?("y")
      end
      ok ? 0 : 1
    end

    # One line for the profile; false when it (or a member) failed.
    def install_profile(name, dry_run)
      profile_line(@bundles.install(name, dry_run: dry_run), dry_run)
    rescue StandardError => e
      @stdout.puts("#{name} bundles: failed (#{e.message.lines.first.to_s.strip})")
      false
    end

    def dev_to_install
      @bundles.to_install(DEV)
    rescue StandardError
      []
    end

    def system_bundle_line(result, dry_run)
      version = "v#{result.to || result.from}"
      text = case result.status
             when :installed then dry_run ? "would install #{version}" : "#{version} installed"
             when :updated then "#{result.from} → #{result.to} #{dry_run ? "would update" : "updated"}"
             when :restored then "#{version} #{dry_run ? "would restore" : "restored"} missing files"
             when :up_to_date then "#{version} up to date"
             when :newer_installed then "v#{result.from} left as is (newer than this chi's v#{result.to})"
             when :skipped then "skipped (#{result.error})"
             else "failed (#{result.error})"
             end
      @stdout.puts("system bundle: #{text}")
      result.status != :failed
    end

    def profile_line(result, dry_run = false)
      parts = []
      parts << "#{dry_run ? "would install" : "installed"} #{result.installed.join(", ")}" unless result.installed.empty?
      parts << "already installed #{result.already.join(", ")}" unless result.already.empty?
      result.skipped.each { |member, why| parts << "skipped #{member} (#{why})" }
      result.failed.each { |member, why| parts << "#{member} failed (#{why})" }
      parts << "nothing new to install" if parts.empty?
      @stdout.puts("#{result.name} bundles: #{parts.join("; ")}")
      !result.failed?
    end

    # The hosts entry: host/port for a plain http server (api: openai when it
    # isn't llama.cpp), url for https or a URL with its own path.
    def host_fields(candidate, native, key_env)
      fields = if candidate.url || candidate.scheme == "https"
                 { "url" => native ? candidate.root : candidate.base }
               else
                 { "host" => candidate.host, "port" => candidate.port }
               end
      fields["api"] = "openai" unless native
      fields["api_key_env"] = key_env if key_env
      fields
    end

    def report(outcome, model)
      path = outcome.path
      case outcome.kind
      when :dry_run
        @stdout.puts("dry run: would write #{outcome.where} (#{path}):")
        @stdout.puts(outcome.text.gsub(/^/, "  "))
        @stdout.puts("and print: #{outcome.model_hint}") if outcome.model_hint
        install_bundles(dry_run: true)
      when :new
        @stdout.puts("config: #{path} (new)")
        0
      when :appended
        @stdout.puts("config: #{path} (hosts entry '#{outcome.name}' added; backup #{File.basename(outcome.backup)})")
        @stdout.puts("default.model: #{outcome.default_model}") if outcome.default_model
        @stdout.puts("add under default: in config.yml:\n#{outcome.model_hint}") if outcome.model_hint
        @stdout.puts("use it: chi --model #{outcome.name}:#{model}   (or /model in a session)") unless outcome.default_model
        0
      when :exists
        @stdout.puts("config: #{path} already has this server as '#{outcome.existing}'; nothing written")
        @stdout.puts("use it: chi --model #{outcome.existing}:#{model}   (or /model in a session)")
        0
      when :snippet
        @stdout.puts("config: #{path} uses YAML chi won't edit (flow style or anchors); add this yourself:")
        @stdout.puts(outcome.text.gsub(/^/, "  "))
        @stdout.puts("use it: chi --model #{outcome.name}:#{model}")
        0
      else
        @stderr.puts("chi bootstrap: the edited #{path} didn't read back as expected; " \
                     "it is back as it was (#{File.basename(outcome.backup)}). Add this yourself:")
        @stderr.puts(outcome.text.gsub(/^/, "  "))
        1
      end
    end

    def next_steps
      dev = dev_to_install
      bundles = dev.empty? ? ["chi bundle list", "the installed bundles"] : ["chi bundle install #{DEV}", "more bundles (#{dev.join(", ")})"]
      lines = [["chi", "a session"], ["chi web --open", "the web UI"], bundles]
      lines << ["chi desktop install", "macOS \"Send to chi\" helper"] if @platform.to_s.include?("darwin")
      lines.each_with_index do |(command, what), i|
        @stdout.puts("#{i.zero? ? "next:" : "     "}  #{command.ljust(22)} # #{what}")
      end
    end

    # A numbered list (the first PICK_SHOWN; a typed word narrows it).
    def pick(items, noun)
      shown = items
      loop do
        shown.first(PICK_SHOWN).each_with_index { |item, i| @stdout.puts(format("  %2d) %s", i + 1, item)) }
        more = shown.size - PICK_SHOWN
        @stdout.puts("  … #{more} more: type part of a name to narrow the list") if more.positive?
        @stdout.print("#{noun} (number#{items.size > PICK_SHOWN ? " or text" : ""}, empty to stop): ")
        answer = @stdin.gets.to_s.strip
        return nil if answer.empty?

        number = Integer(answer, exception: false)
        return shown[number - 1] if number && number.between?(1, [shown.size, PICK_SHOWN].min)

        narrowed = items.select { |item| item.downcase.include?(answer.downcase) }
        if narrowed.empty?
          @stdout.puts("no #{noun} matches '#{answer}'")
        else
          shown = narrowed
          return shown.first if shown.size == 1
        end
      end
    end

    def tty?
      @stdin.respond_to?(:tty?) && @stdin.tty?
    end

    def unset?(name) = @env[name].to_s.strip.empty?

    def fail!(message)
      @stderr.puts("chi bootstrap: #{message}")
      @exit = 1
      nil
    end
  end
end
