# frozen_string_literal: true

require "yaml"
require "fileutils"

module Samagotchi
  module ConfigFile
    XDG_CONFIG_HOME_ENV = "XDG_CONFIG_HOME"
    CONFIG_DIR = "samagotchi"
    CONFIG_FILE = "config.yml"
    DEFAULT_MODEL_KEY = "SAMAGOTCHI_DEFAULT_MODEL"
    MODEL_ALIASES_KEY = "model_aliases"

    module_function

    def load_global_env!(env: ENV, path: global_path(env: env))
      return false unless File.file?(path)

      parse_file(path).each do |key, value|
        env[key] = value unless env.key?(key)
      end

      true
    end

    def global_path(env: ENV)
      config_home = env.fetch(XDG_CONFIG_HOME_ENV, "").to_s.strip
      base_dir = config_home.empty? ? File.expand_path("~/.config") : config_home
      File.join(base_dir, CONFIG_DIR, CONFIG_FILE)
    end

    def parse_file(path)
      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      return {} if data.nil?

      unless data.is_a?(Hash)
        raise ArgumentError, "global config must be a YAML mapping: #{path}"
      end

      data.each_with_object({}) do |(key, value), result|
        next if value.nil?

        unless scalar_value?(value)
          # Skip non-scalar values (e.g., nested hashes, arrays).
          # This allows the config file to contain sections like `hooks:` that
          # are parsed separately by other subsystems (e.g. Hooks::Loader).
          next
        end

        result[key.to_s] = value.to_s
      end
    end

    def scalar_value?(value)
      value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
    end
    private_class_method :scalar_value?

    def write_default_model!(model_name, env: ENV, path: global_path(env: env))
      resolved = model_name.to_s.strip
      raise ArgumentError, "model name is required" if resolved.empty?

      # Load raw YAML (including nested sections like hooks:) so we don't clobber them
      raw_data = {}
      if File.file?(path)
        loaded = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
        raw_data = loaded if loaded.is_a?(Hash)
      end

      raw_data[DEFAULT_MODEL_KEY] = resolved
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      File.write(tmp, YAML.dump(raw_data))
      File.rename(tmp, path)
      env[DEFAULT_MODEL_KEY] = resolved
      true
    end

    def model_aliases(env: ENV, path: global_path(env: env))
      return {} unless File.file?(path)

      data = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      return {} unless data.is_a?(Hash)

      raw = data[MODEL_ALIASES_KEY]
      return {} if raw.nil?
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(k, v), result|
        key = k.to_s.strip
        next if key.empty?
        val = v.to_s.strip
        next if val.empty?

        result[key.downcase] = val
      end
    rescue StandardError
      {}
    end

    def resolve_model_alias(raw, env: ENV, path: global_path(env: env))
      value = raw.to_s.strip
      return value if value.empty?

      aliases = model_aliases(env: env, path: path)
      aliases.fetch(value.downcase, value)
    end
  end
end
