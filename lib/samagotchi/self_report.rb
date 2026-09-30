# frozen_string_literal: true

require "json"
require_relative "version"
require_relative "config"
require_relative "context_window"
require_relative "session"
require_relative "log_path"
require_relative "model_profile"
require_relative "thinking"
require_relative "served_model"
require_relative "host_registry"
require_relative "tools/memory"
require_relative "hooks/loader"
require_relative "memory_bundle/provenance"
require_relative "memory_bundle/manifest"
require_relative "memory_bundle/system_bundle"
require_relative "desktop"
require_relative "live_versions"
require_relative "web/lan"

module Samagotchi
  # `chi self`: where this chi lives and what it is configured to use.
  #
  # Read-only and nearly offline (one short /props GET for the served model,
  # nothing else asks a model server; one /api/info GET on this machine's
  # chi web port), so the agent can run it via `execute`
  # to orient itself — source dir to rg, config path, memory dirs, sessions,
  # model/host, bundle versions — without guessing from $PATH.
  module SelfReport
    SOURCE_DIR = File.expand_path("../..", __dir__)

    module_function

    def text(env: ENV)
      rows = fields(env: env)
      width = rows.map { |label, _| label.length }.max
      rows.map { |label, value| "#{label.ljust(width)}  #{value}" }.join("\n")
    end

    def fields(env: ENV)
      model = model_name
      [
        ["version", "#{VERSION} (ruby #{RUBY_VERSION})"],
        ["source", "#{SOURCE_DIR} (#{install_kind})"],
        ["config", with_presence(ConfigFile.global_path(env: env))],
        ["hooks dir", hooks_dir(env)],
        ["memories", Tools::MemoryRead.memories_dir("system", env: env)],
        ["project memories", Tools::MemoryRead.memories_dir("project", env: env)],
        ["sessions", Session.default_state_dir(env: env)],
        ["log", log_path(env)],
        ["model", model || "(not configured)"],
        ["host", model ? host_for(model, env) : "-"],
        ["api key", model ? api_key_for(model, env) : "-"],
        ["loop", model ? loop_for(model, env) : "-"],
        ["profile", model ? profile_for(model, env) : "-"],
        ["thinking", model ? thinking_for(model, env) : "-"],
        ["served model", model ? served_model_for(model, env) : "-"],
        ["context window", context_window(env)],
        ["bundles", bundles_summary],
        ["desktop", desktop_summary(env)],
        ["chi web", web_summary]
      ]
    end

    WEB_TIMEOUT = 0.3

    # Whether a chi web answers on this machine's web port, and whether a
    # phone can reach it (LAN mode: /api/info's lan).
    def web_summary
      port = Config.get("web.port").to_i
      port = 4567 unless port.positive?
      info = LiveVersions.web_info(Web::Lan.local_host(Config.get("web.host")), port, timeout: WEB_TIMEOUT)
      return "not running on port #{port}" unless info
      return "LAN on #{info["lan"]}:#{port} (and 127.0.0.1)" if info["lan"]

      "on 127.0.0.1:#{port} (this machine only)"
    end

    # "git checkout" when running from a repo (bin/chi), "installed gem" when
    # under a gem path; the installed gem's files are not meant to be edited.
    def install_kind(dir = SOURCE_DIR)
      return "git checkout" if File.exist?(File.join(dir, ".git"))
      return "installed gem" if Gem.path.any? { |p| dir.start_with?(File.join(p, "gems") + File::SEPARATOR) }

      "directory"
    end

    # The debug log every chi process appends to (LogPath): the sessions
    # dir's sibling by default, so a chi that wants to read its own trail
    # doesn't guess ~/.local/state.
    def log_path(env)
      LogPath.resolve(env: env) || "(disabled: log.disable)"
    end

    def with_presence(path)
      File.exist?(path) ? path : "#{path} (missing)"
    end

    def hooks_dir(env)
      data = ConfigFile.read_yaml(path: ConfigFile.global_path(env: env))
      configured = data.is_a?(Hash) && data["hooks"].is_a?(Hash) ? data["hooks"]["hooks_dir"] : nil
      Hooks::Loader.expand_path(configured || Hooks::Loader.default_hooks_dir(env), env)
    end

    # Offline, so only the fallback: the running server's n_ctx wins at runtime.
    def context_window(env)
      window = ContextWindow.configured(env: env)
      "#{window.tokens} (#{window.source}; the server's n_ctx wins at runtime)"
    end

    def model_name
      ModelProfile.required_model_name
    rescue ArgumentError
      nil
    end

    # Routed without model discovery, so an unqualified name may land on
    # another host at runtime after /models.
    def loop_for(model, env)
      entry, = HostRegistry.new(env: env).host_for_model(model)
      return "-" unless entry

      entry.chat? ? "chat (api: openai)" : "native (raw prompt)"
    end

    # chi self's one server call: a single-model llama.cpp answers any name
    # with the model it loaded, and its /props names it (model_alias). One
    # GET with the probe's short timeouts; a remote host isn't asked.
    def served_model_for(model, env)
      registry = HostRegistry.new(env: env)
      entry, bare = registry.host_for_model(model)
      return "-" unless entry
      return "reported per turn (remote host)" if entry.remote?

      client = registry.client_for(entry)
      props = client.server_props(model: bare) if client.respond_to?(:server_props)
      return "reported per turn (the server has no /props)" if props.nil?
      return "unknown (the server didn't answer; is it running?)" if props.status == :network_error

      served = ServedModel.from_props(props)
      return "unknown (no answer from the server's /props)" unless served

      ServedModel.differs?(bare, served) ? "#{served} (not #{bare}: the server serves its own model)" : served
    rescue StandardError => e
      "unknown (#{e.class})"
    end

    # Offline, so no /props probe: where nothing is configured, a native
    # llama.cpp host's chat template decides at runtime.
    def profile_for(model, env)
      registry = HostRegistry.new(env: env)
      entry, bare = registry.host_for_model(model)
      return "name-based (chat API: only strips thoughts)" if entry&.chat?

      # As typed, the part after a host prefix (maybe an alias), alias-resolved, bare.
      names = [model, registry.parse_qualified_model(model).last, ConfigFile.resolve_model_alias(model, env: env), bare]
      override = Config.resolve_with_origin("model.profile", env: env, cli_overrides: Config.cli_overrides)
      result = ModelProfile.resolve(names: names, entry: entry, client: nil, bare_model: bare, override: override,
                                    models: ConfigFile.model_settings(env: env))
      name = result.profile.name
      case result.source
      when :config then "#{name} (config #{result.detail})"
      when :cli, :env then "#{name} (#{result.source})"
      else
        return "#{name} (#{result.source})" unless entry.nil? || entry.transport.nil? || entry.transport == :llama_cpp

        given = result.source == :name ? "name says #{name}" : "default #{name}"
        "from the server at runtime (#{given})"
      end
    end

    # The model's thinking level and where it came from (Thinking.resolve).
    def thinking_for(model, env)
      target = HostRegistry.new(env: env).resolve(model)
      level, source = Thinking.resolve(target, models: ConfigFile.model_settings(env: env))
      source ? "#{level} (#{source})" : level.to_s
    rescue StandardError => e
      "(unknown: #{e.message})"
    end

    def host_for(model, env)
      entry, bare = HostRegistry.new(env: env).host_for_model(model)
      return "(no hosts configured)" unless entry

      suffix = bare && bare != model ? " as #{bare}" : ""
      location = entry.url || "#{entry.host}:#{entry.port}"
      "#{entry.name} #{location}#{suffix}"
    end

    # The variable the host's API key comes from and whether it is set; the
    # key itself is never shown.
    def api_key_for(model, env)
      entry, = HostRegistry.new(env: env).host_for_model(model)
      name = entry&.api_key_env
      return "-" unless name

      "#{name} (#{env[name].to_s.empty? ? "unset" : "set"})"
    end

    # The Chi Helper app's version against this chi's (read from its
    # Info.plist and launch file; no process or Services checks: chi desktop
    # status has those). An older app is fine while its sources are unchanged.
    def desktop_summary(env)
      return "- (macOS only)" unless Desktop.supported?

      helper = Desktop::MacOS.new(env: env)
      version = helper.app_version
      return "not installed" unless version
      return "#{version} (matches)" if version == VERSION

      helper.stale? ? "#{version} (chi is #{VERSION}: chi update)" : "#{version} (up to date for chi #{VERSION})"
    end

    # "samagotchi-system 0.1.5 (shipped 0.1.5), other 1.0.0"
    def bundles_summary
      shipped = MemoryBundle::Manifest.read(dir: MemoryBundle::SystemBundle::GEM_BUNDLE_DIR).version rescue nil
      installed = Dir[File.join(MemoryBundle::Provenance.bundles_dir, "*", "manifest.json")].sort.map do |path|
        name = File.basename(File.dirname(path))
        version = (JSON.parse(File.read(path))["version"] rescue nil) || "?"
        label = "#{name} #{version}"
        label += " (shipped #{shipped})" if name == MemoryBundle::SystemBundle::BUNDLE_NAME
        label
      end
      installed.empty? ? "(none installed; shipped system bundle #{shipped || "?"})" : installed.join(", ")
    end
  end
end
