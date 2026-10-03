# frozen_string_literal: true

require "json"
require_relative "version"
require_relative "config"
require_relative "context_window"
require_relative "session"
require_relative "log_path"
require_relative "model_profile"
require_relative "model_overlay"
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
      default = model_name
      model = session_model(env) || default
      [
        ["version", "#{VERSION} (ruby #{RUBY_VERSION})"],
        ["source", "#{SOURCE_DIR} (#{install_kind})"],
        ["config", with_presence(ConfigFile.global_path(env: env))],
        ["hooks dir", hooks_dir(env)],
        ["memories", Tools::MemoryRead.memories_dir("system", env: env)],
        ["project memories", Tools::MemoryRead.memories_dir("project", env: env)],
        ["sessions", Session.default_state_dir(env: env)],
        ["log", log_path(env)],
        ["model", model ? model_label(model, default, env) : "(not configured)"],
        ["model key", model ? model_key_for(model, env) : "-"],
        ["host", model ? host_for(model, env) : "-"],
        ["api key", model ? api_key_for(model, env) : "-"],
        ["loop", model ? loop_for(model, env) : "-"],
        ["profile", model ? profile_for(model, env) : "-"],
        ["thinking", model ? thinking_for(model, env) : "-"],
        ["served model", model ? served_model_for(model, env) : "-"],
        ["context window", context_window(env, model)],
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

    def hooks_dir(env) = Hooks::Loader.hooks_dir(env)

    # Offline, so only the fallback: the running server's n_ctx wins at runtime.
    # The window config gives the current model (ContextWindow: its
    # models.<key>.window_tokens, its host's, then context.window_tokens or
    # the default) and which of them, as a turn resolves it offline.
    def context_window(env, model = nil)
      tokens, where = model_window(env, model) || ContextWindow.configured(env: env).to_h.values_at(:tokens, :source)
      "#{tokens} (#{where}; the server's n_ctx wins at runtime)"
    end

    # [tokens, "models: KEY" | "hosts.NAME"], or nil when neither is set.
    def model_window(env, model)
      return nil unless model

      registry = HostRegistry.new(env: env)
      target = registry.resolve(model)
      names = registry.lookup_names(model, target: target)
      models = ConfigFile.model_settings(env: env)
      window = ContextWindow.setting(target, names: names, models: models)
      return nil unless window
      return [window.tokens, "hosts.#{target.entry.name}"] if window.source == :host_setting

      [window.tokens, "models: #{ConfigFile.model_setting(names, :window_tokens, models: models).first}"]
    rescue StandardError
      nil
    end

    SESSION_MODEL_ENV = "SAMAGOTCHI_SESSION_MODEL"
    PARENT_SESSION_ENV = "SAMAGOTCHI_PARENT_SESSION"

    # The model of the session this chi self runs in (its execute exports
    # SAMAGOTCHI_SESSION_MODEL, the resolved ref, live after /model); nil
    # outside a session's commands.
    def session_model(env)
      name = env[SESSION_MODEL_ENV].to_s.strip
      name.empty? ? nil : name
    end

    # "splash:x (this session abcd1234; default main:y)", "main:y (this
    # session abcd1234, the default)", or outside a session "main:y (default)".
    def model_label(model, default, env)
      return "#{model} (default)" unless session_model(env)

      id = env[PARENT_SESSION_ENV].to_s
      session = id.empty? || id == "chi" ? "this session" : "this session #{id[0, 8]}"
      return "#{model} (#{session}, the default)" if default && same_model?(model, default, env)

      "#{model} (#{session}; default #{default || "not configured"})"
    end

    def same_model?(one, other, env)
      return true if one == other

      ConfigFile.model_ref(one, env: env).ref == ConfigFile.model_ref(other, env: env).ref
    rescue StandardError
      false
    end

    # The memory overlay key (ModelOverlay.key_for the bare id, as the
    # engine keys memory_write current_model_only): which `<name>.<key>.md`
    # overlays are this model's.
    def model_key_for(model, env)
      ModelOverlay.key_for(HostRegistry.new(env: env).bare_name(model)) || "-"
    rescue StandardError
      ModelOverlay.key_for(model) || "-"
    end

    def model_name
      ModelProfile.required_model_name
    rescue ArgumentError
      nil
    end

    # `chi self --model`, the desktop helper's hint: the default as the ref
    # it resolves to (an alias applied, ModelRef), as `chi models` names it.
    def model_ref_name(env: ENV)
      name = model_name
      name && ConfigFile.model_ref(name, env: env).ref
    end

    # Routed without model discovery, so an unqualified name may land on
    # another host at runtime after /models.
    def loop_for(model, env)
      entry = HostRegistry.new(env: env).resolve(model).entry
      return "-" unless entry

      entry.chat? ? "chat (api: openai)" : "native (raw prompt)"
    end

    NO_PROPS = "reported per turn (the server has no /props)"

    # chi self's one server call: a single-model llama.cpp answers any name
    # with the model it loaded, and its /props names it (model_alias). One
    # GET with the probe's short timeouts; a remote host isn't asked.
    def served_model_for(model, env)
      registry = HostRegistry.new(env: env)
      target = registry.resolve(model)
      entry = target.entry
      bare = target.bare_model
      return "-" unless entry
      return "reported per turn (remote host)" if entry.remote?
      return NO_PROPS if entry.chat?

      client = registry.client_for(entry)
      props = client.server_props(model: bare)
      return NO_PROPS if props.nil? || props.status == :http_error
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
      target = registry.resolve(model)
      entry = target.entry
      bare = target.bare_model
      return "name-based (chat API: only strips thoughts)" if entry&.chat?

      names = registry.lookup_names(model)
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
      registry = HostRegistry.new(env: env)
      target = registry.resolve(model)
      level, source = Thinking.resolve(target, names: registry.lookup_names(model, target: target),
                                               models: ConfigFile.model_settings(env: env))
      source ? "#{level} (#{source})" : level.to_s
    rescue StandardError => e
      "(unknown: #{e.message})"
    end

    def host_for(model, env)
      target = HostRegistry.new(env: env).resolve(model)
      entry = target.entry
      bare = target.bare_model
      return "(no hosts configured)" unless entry

      suffix = bare && bare != model ? " as #{bare}" : ""
      location = entry.url || "#{entry.host}:#{entry.port}"
      "#{entry.name} #{location}#{suffix}"
    end

    # The variable the host's API key comes from and whether it is set; the
    # key itself is never shown.
    def api_key_for(model, env)
      name = HostRegistry.new(env: env).resolve(model).entry&.api_key_env
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
      installed = MemoryBundle::Provenance.each_installed.map do |name, data|
        version = data[:version] || "?"
        label = "#{name} #{version}"
        label += " (shipped #{shipped})" if name == MemoryBundle::SystemBundle::BUNDLE_NAME
        label
      end
      installed.empty? ? "(none installed; shipped system bundle #{shipped || "?"})" : installed.join(", ")
    end
  end
end
