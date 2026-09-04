# frozen_string_literal: true

require "yaml"
require "fileutils"

module Samagotchi
  module ConfigFile
    XDG_CONFIG_HOME_ENV = "XDG_CONFIG_HOME"
    CONFIG_DIR = "samagotchi"
    CONFIG_FILE = "config.yml"
    DEFAULT_MODEL_KEY = "SAMAGOTCHI_DEFAULT_MODEL"

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
  end
end
