# frozen_string_literal: true

require "optparse"
require_relative "config"
require_relative "model_profile"
require_relative "thinking"
require_relative "version"

module Samagotchi
  # bin/chi's run flags: the one OptionParser for `chi [options]` (a
  # session, chi scratch, chi web), with the checks it runs before and
  # around the parse (underscored flags, a flag where -p's text should be,
  # --no-tool). What is wrong is said on stderr and exits, as bin/chi did.
  module RunOptions
    # The flags an underscored spelling is refused for (--recap_base_url),
    # with the config registry's.
    KNOWN = %w[--prompt --resume --attach --shared --no-shared --model --thinking --toolkit --tool --no-tool --set --parent-answers --memory --mute --append-system-prompt --dir --llm-context --llm-context-apply --llm-context-budget --no-interrupt --non-interactive --verbose --no-default-input --port --open --new-token --tunnel].freeze

    module_function

    # Parse +argv+ in place: what the parser leaves is bin/chi's to read
    # (`web`, or a stray word).
    # @param argv [Array<String>] bin/chi's ARGV (changed)
    # @return [Array(Hash, Hash)] the options and the config overrides
    #   (Config.reload!'s cli_overrides)
    def parse(argv)
      # no_interrupt / no_default_input start from config.yml or the env; the flags below turn them on.
      options = { verbose: false, no_interrupt: Samagotchi::Config.get("no_interrupt"), non_interactive: false, no_default_input: Samagotchi::Config.get("no_default_input"), web: false, web_port: nil, web_open: false, web_markdown: nil }
      cli_overrides = {}

      # Strict kebab enforcement: --recap_base_url is unknown (OptionParser would otherwise accept _ as -)
      known = KNOWN + Samagotchi::Config.cli_entries.map(&:cli_flag)
      argv.each do |arg|
        next unless arg.start_with?("--") && arg.include?("_")

        # Allow --no-interrupt etc. already dash; underscore is always rejected for config flags
        # We check raw argv before OptionParser normalizes
        base = arg.split("=", 2).first
        # If dashed version is a known flag (registry or hardcoded), reject underscore variant
        dashed = base.tr("_", "-")
        if known.include?(dashed) || known.include?(base)
          warn "Unknown option: #{arg} (did you mean #{dashed}?)"
          exit 1
        end
      end

      parser = build_parser(options, cli_overrides)
      # --no-tool NAME (or --no-tool=NAME), up to a "--". A flag that takes a
      # value (-p, --model …: the parser's own list) keeps its next word, so
      # `chi -p "--no-tool=x is broken"` is a prompt. A tool name never starts
      # with "-": `--no-tool --` or `--no-tool --model` is a missing argument.
      switches = parser_switches(parser)
      switch_flags = switches.flat_map { |switch| switch.long + switch.short }
      known_flags = (known + switch_flags).uniq
      takes_value = switches.select { |switch| switch.is_a?(OptionParser::Switch::RequiredArgument) }
                            .flat_map { |switch| switch.long + switch.short }
      reject_prompt_flag = lambda do |flag, value|
        if known_flags.include?(value)
          warn "Error: #{flag} needs the prompt text right after it (got the flag #{value}) (see chi --help)"
          exit 2
        end
      end
      index = 0
      while index < argv.size && argv[index] != "--"
        arg = argv[index]
        if %w[-p --prompt].include?(arg)
          reject_prompt_flag.call(arg, argv[index + 1])
          index += 2
        elsif arg.start_with?("--prompt=")
          reject_prompt_flag.call("--prompt", arg.delete_prefix("--prompt="))
          index += 1
        elsif arg.start_with?("-p") && arg != "-p"
          reject_prompt_flag.call("-p", arg.delete_prefix("-p").delete_prefix("="))
          index += 1
        else
          index += takes_value.include?(arg) ? 2 : 1
        end
      end
      missing_no_tool = lambda do
        warn "Error: missing argument: --no-tool (see chi --help)"
        exit 1
      end
      # A flag's whole name only, as the subcommands' CLI::Flags take them:
      # an abbreviation (--verb, --mem x) is an unknown option, never read
      # past chi --remote's Contract::RUN. Checked here rather than with
      # OptionParser#require_exact: Ruby 3.3's optparse (0.4) refuses both
      # spellings of a --[no-]x switch with it, and crashes on a bare "--".
      long_flags = switch_flags.flat_map { |flag| flag.include?("[no-]") ? [flag.sub("[no-]", ""), flag.sub("[no-]", "no-")] : [flag] }
                               .select { |flag| flag.start_with?("--") }.push("--no-tool")
      reject_abbreviation = lambda do |arg|
        return unless arg.start_with?("--") && !long_flags.include?(arg.split("=", 2).first)

        warn "Error: invalid option: #{arg} (see chi --help)"
        exit 1
      end
      index = 0
      while index < argv.size && argv[index] != "--"
        arg = argv[index]
        if arg == "--no-tool"
          value = argv[index + 1]
          missing_no_tool.call if value.nil? || value.start_with?("-")
          (options[:no_tools] ||= []) << argv.delete_at(index + 1)
          argv.delete_at(index)
        elsif arg.start_with?("--no-tool=")
          value = arg.delete_prefix("--no-tool=")
          missing_no_tool.call if value.empty? || value.start_with?("-")
          options[:no_tools] = (options[:no_tools] || []) << value
          argv.delete_at(index)
        else
          reject_abbreviation.call(arg)
          index += takes_value.include?(arg) ? 2 : 1
        end
      end
      begin
        parser.parse!(argv)
      rescue OptionParser::ParseError => e
        warn "Error: #{e.message} (see chi --help)"
        exit 1
      end

      [options, cli_overrides]
    end

    # The switches that take a value (--model NAME, -p TEXT), long and
    # short: a word after one is its value, not a flag.
    # @return [Array<String>]
    def value_switches
      parser_switches(build_parser({}, {})).select { |switch| switch.is_a?(OptionParser::Switch::RequiredArgument) }
                                           .flat_map { |switch| switch.long + switch.short }.push("--no-tool").uniq
    end

    # Every switch the parser takes, long and short, a --[no-]x as --x and
    # --no-x (--no-tool too, read before the parse), for what classifies the
    # run flags.
    # @return [Array<String>]
    def switches
      flags = parser_switches(build_parser({}, {})).flat_map { |switch| switch.long + switch.short }
      flags.flat_map { |flag| flag.include?("[no-]") ? [flag.sub("[no-]", ""), flag.sub("[no-]", "no-")] : [flag] }
           .push("--no-tool").uniq
    end

    # The parser's switches (OptionParser::Switch), short and long.
    def parser_switches(parser)
      parser.instance_variable_get(:@stack).flat_map { |list| list.list }
            .select { |switch| switch.is_a?(OptionParser::Switch) }
    end

    # @param options [Hash] filled in by the parse
    # @param cli_overrides [Hash] the config keys the flags set
    def build_parser(options, cli_overrides)
      OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Usage: chi [options]
                 chi bootstrap [HOST[:PORT]|URL]  first setup: find the model server, write config.yml
                 chi scratch [options]            a one-time session in this terminal: nothing is kept
                 chi web [--port PORT] [--open] [--scope=all]   the web UI
                 chi web push <ls|rm|test>        the phones chi web pushes notifications to
                 chi sessions <list|stop|restart|archive|unarchive|delete|prune|clean|stats>
                 chi note [--source NAME] [-m TEXT] ID...|--all   background context for sessions
                 chi broadcast [-m TEXT] [--all] [--dry-run] | log | deliver   a note for every session it may concern
                 chi context <add|push|ls|show|refresh|rm|mute|unmute>   live external text attached to sessions
                 chi send [-m TEXT] ID...|--new   a message into sessions, as if typed there
                 chi answer ID --question QID --option N   answer a question a session waits on
                 chi share ID --name NAME | ls [ID] | cap ID P D | revoke ID [P]|--all   participants who review a session
                 chi review FILE... [--dir DIR] | --from ID   a review session to share (chi share)
                 chi memory <ls|rm> [--scope project|system]   the memories; rm moves one to the bundle trash
                 chi bundle <install|upgrade|uninstall|status|diff|list|build|trash|new|test|check|try>
                 chi desktop <install|upgrade|uninstall|status>   macOS "Send to chi" helper
                 chi models [--format json] [TEXT]   the models --model takes, from every host
                 chi remote <add|ls|rm>           other machines' chi web, for chi --remote NAME
                 chi --remote NAME <send|answer|note|context|sessions|share|review> …   those commands on that machine (or CHI_REMOTE=NAME)
                 chi --remote NAME --attach ID | --resume ID | --dir DIR [-p TEXT]   a session on that machine, in this terminal
                 chi self                         version, paths, model and bundles
                 chi update [--dry-run]           update this chi, its bundles and the desktop helper
          (each subcommand takes --help)

        BANNER
        opts.on("-p", "--prompt PROMPT", "Run PROMPT as the first turn, then stay in the session (attached; the REPL with --no-shared)") { |p| options[:prompt] = p }
        opts.on("--resume SESSION_ID", "Resume a previous session by its ID (or a unique prefix of it)") { |s| options[:resume] = s }
        opts.on("--attach SESSION_ID", "Attach to a session's worker, waking one if it has exited; ID or a unique prefix") { |s| options[:attach] = s }
        opts.on("--dir DIR", "With --remote: a new session's folder on that machine, its absolute path (required there; " \
                             "here cd instead)") { |d| options[:dir] = d }
        opts.on("--[no-]shared", "Run the session in a background worker and attach to it, so `chi web` can share it (the default, config session.shared; with --resume: that session); --no-shared runs a plain in-process REPL") { |v| options[:shared] = v }
        opts.on("--model NAME", "Model for this run, not saved (overrides --resume's; config default.model) [env SAMAGOTCHI_DEFAULT_MODEL]") { |m| options[:model] = m; cli_overrides["default.model"] = m }
        opts.on("--profile NAME", Samagotchi::ModelProfile::NAMES,
                "Prompt profile for every model in this run (#{Samagotchi::ModelProfile::NAMES.join("|")}) [alias for --model-profile]") { |p| cli_overrides["model.profile"] = p }
        opts.on("--thinking LEVEL", Samagotchi::Thinking::LEVELS.map(&:to_s), "This session's own thinking level: off|low|medium|high|default (saved in the session, " \
                                    "before the model's; default unsets it; /thinking changes it). With chi web: the default for the sessions " \
                                    "its workers run, below a session's own [env SAMAGOTCHI_THINKING_LEVEL]") { |l| options[:thinking] = l }
        opts.on("--toolkit NAME", "This session's toolkit, the tools its prompts declare: full|lean|child|a config or bundle one " \
                                 "(saved in the session; config toolkit.default; /toolkit changes it)") { |n| options[:toolkit] = n }
        opts.on("--tool NAME", "Also declare this tool on top of the toolkit (repeatable; a comma list too)") { |t| (options[:tools] ||= []) << t }
        # --no-tool is taken out of ARGV before parse! (OptionParser would read it
        # as --tool's negation); this is its help line.
        opts.separator "        --no-tool NAME               Leave this tool out of the toolkit (repeatable; a comma list too)"
        opts.on("--set KEY=VALUE", "A setting for this session, saved in it (repeatable): a core key a session may set " \
                                   "(recap.enabled, recap.sentences; typed by the key, over CLI, env and config.yml), or BUNDLE.KEY over " \
                                   "config.yml's bundles: (a key the bundle's manifest lists in session_settings:; numbers and booleans " \
                                   "(true, off, no) are typed, the rest is text). A wrong key or value is refused: " \
                                   "--set recap.enabled=false, --set cost-cap.cap=3") do |v|
          (options[:sets] ||= []) << v
        end
        opts.on("--parent-answers LEVEL", "What a parent agent may answer on this session's questions: " \
                                          "hard|standard|soft, only stricter than config.yml's guardrails.parent_answers (saved in the " \
                                          "session; only you loosen it, with /parent-answers in the terminal or the web)") do |v|
          options[:parent_answers] = v
        end
        opts.on("--memory NAME", "Preload a memory entry into the system prompt (repeatable; a comma list too)") { |m| (options[:memories] ||= []) << m }
        opts.on("--append-system-prompt FILE", "Put FILE's text into the system prompt, after AGENTS.md (repeatable; saved in the session; " \
                                              "config append_system_prompt: is the baseline)") { |f| (options[:append_system_prompt] ||= []) << f }
        opts.on("--mute NAME", "Hide a memory from this session: not in the prompt, refused by memory_read (repeatable; a comma list too)") { |m| (options[:muted] ||= []) << m }
        opts.on("--llm-context LAYERS", "This session's own LLM context strategy: none, or layers such as stale,forget (saved in the session, " \
                                       "before the model's; /llm-context changes it)") { |v| (options[:llm_context] ||= {})[:strategy] = v }
        opts.on("--llm-context-apply RULE", "This session's own apply rule for it: payoff|next_request|turn_end") { |v| (options[:llm_context] ||= {})[:apply] = v }
        opts.on("--llm-context-budget TOKENS", "This session's own context budget: tokens (64000, 64k) or off") { |v| (options[:llm_context] ||= {})[:budget_tokens] = v }
        opts.on("--no-interrupt", "Raise the tool call limit to 1000 iterations (useful for long tasks)") { options[:no_interrupt] = true; cli_overrides["no_interrupt"] = true }
        opts.on("--non-interactive", "Run a single prompt and exit (no REPL, implies --no-interrupt)") { options[:non_interactive] = true }
        opts.on("-v", "--verbose", "Print raw LLM responses and tool calls/results (runs a plain REPL, not attached)") { options[:verbose] = true }
        opts.on("--no-default-input", "Skip default REPL input prefill") { options[:no_default_input] = true; cli_overrides["no_default_input"] = true }
        opts.on("--port PORT", "Port for `chi web` (default: 4567, env SAMAGOTCHI_WEB_PORT)") { |p| options[:web_port] = p.to_i; cli_overrides["web.port"] = p.to_s }
        opts.on("--open", "Open browser for `chi web`") { options[:web_open] = true }
        opts.on("--new-token", "`chi web`: replace the LAN access token (web.host: lan); links and QR codes made with the old one stop working") { options[:new_token] = true }
        opts.on("--tunnel PROVIDER", %w[tailscale],
                "`chi web`: reach it over https from your tailnet through Tailscale Serve (never Funnel), for this run; " \
                "turned off on exit") { |v| options[:tunnel] = v }
        opts.on("--scope VALUE", %w[project all],
                "Which sessions `chi web` and `chi sessions list` show: project (the default: this folder's git project; " \
                "every session outside a repo) or all") { |v| options[:scope] = v }
        # Accepted values of string entries that the registry doesn't type as enums.
        value_hints = { "status.line" => "on|off", "web.host" => "127.0.0.1|::1|localhost|lan|IP", "recap.sentences" => "N|N-M",
                        "web.annotate_presets" => "text|text", "web.editor" => "vscode|vscode-insiders|cursor|zed|none|URL" }
        # Universal config flags (implicit convention: ENV SAMAGOTCHI_* ↔ YAML dotted ↔ CLI --kebab)
        # Generated from Samagotchi::Config registry — Option A: snake leaf in YAML, kebab in CLI.
        Samagotchi::Config.cli_entries.each do |entry|
          next if %w[no_interrupt no_default_input].include?(entry.key)
          next if entry.key == "web.port" # already handled as --port
          next if entry.key == "default.model" # alias --model above
          next if entry.key == "web.markdown" # handled below with explicit inverse flags

          case entry.type
          when :bool
            # --[no-]: a bool that defaults to on is only useful switched off.
            opts.on("--[no-]#{entry.cli_flag.delete_prefix("--")}", "Set #{entry.key} (bool, default #{entry.default ? "on" : "off"}) [env #{entry.env_key}]") { |v| cli_overrides[entry.key] = v }
          when :integer, :float, :string, :enum
            desc = "Set #{entry.key} [env #{entry.env_key}]"
            desc += " (#{entry.enum_values.join("|")})" if entry.type == :enum
            desc += " (#{value_hints[entry.key]})" if value_hints.key?(entry.key)
            desc += "; only without a hosts: config" if %w[server.host server.port].include?(entry.key)
            if entry.type == :enum
              opts.on("#{entry.cli_flag} VALUE", entry.enum_values, desc) { |v| cli_overrides[entry.key] = v }
            else
              opts.on("#{entry.cli_flag} VALUE", desc) { |v| cli_overrides[entry.key] = v }
            end
          end
        end
        opts.on("--web-markdown", "Render finalized LLM Markdown in `chi web` (requires optional commonmarker gem)") { options[:web_markdown] = true; cli_overrides["web.markdown"] = true }
        opts.on("--no-web-markdown", "Disable Markdown rendering in `chi web`") { options[:web_markdown] = false; cli_overrides["web.markdown"] = false }
        # Strict underscore rejection: --recap_base_url etc. are not registered and will raise OptionParser::InvalidOption
        opts.on("--version", "Print chi's version") { puts "chi #{Samagotchi::VERSION}"; exit }
        opts.on("-h", "--help", "Show help") { puts opts; exit }
      end
    end
  end
end
