# frozen_string_literal: true

require "json"
require_relative "version"
require_relative "config"
require_relative "session"
require_relative "model_profile"
require_relative "host_registry"
require_relative "llm/backend"
require_relative "tools/memory"
require_relative "hooks/loader"
require_relative "memory_bundle/provenance"
require_relative "memory_bundle/manifest"
require_relative "memory_bundle/system_bundle"

module Samagotchi
  # `chi self`: where this chi lives and what it is configured to use.
  #
  # Read-only and offline (no model server calls), so the agent can run it via
  # `execute` to orient itself — source dir to rg, config path, memory dirs,
  # sessions, model/host, bundle versions — without guessing from $PATH.
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
        ["model", model || "(not configured)"],
        ["host", model ? host_for(model, env) : "-"],
        ["backend", LLM::Factory.resolve_provider(nil, env: env).to_s],
        ["bundles", bundles_summary]
      ]
    end

    # "git checkout" when running from a repo (bin/chi), "installed gem" when
    # under a gem path; the installed gem's files are not meant to be edited.
    def install_kind(dir = SOURCE_DIR)
      return "git checkout" if File.exist?(File.join(dir, ".git"))
      return "installed gem" if Gem.path.any? { |p| dir.start_with?(File.join(p, "gems") + File::SEPARATOR) }

      "directory"
    end

    def with_presence(path)
      File.exist?(path) ? path : "#{path} (missing)"
    end

    def hooks_dir(env)
      data = ConfigFile.read_yaml(path: ConfigFile.global_path(env: env))
      configured = data.is_a?(Hash) && data["hooks"].is_a?(Hash) ? data["hooks"]["hooks_dir"] : nil
      Hooks::Loader.expand_path(configured || Hooks::Loader.default_hooks_dir(env), env)
    end

    def model_name
      ModelProfile.required_model_name
    rescue ArgumentError
      nil
    end

    def host_for(model, env)
      entry, bare = HostRegistry.new(env: env).host_for_model(model)
      return "(no hosts configured)" unless entry

      suffix = bare && bare != model ? " as #{bare}" : ""
      "#{entry.name} #{entry.host}:#{entry.port}#{suffix}"
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
