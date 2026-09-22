# frozen_string_literal: true

require_relative "registry"
require_relative "../config"

module Samagotchi
  module Hooks
    # Plugin-based hook loader that loads Ruby classes from a directory.
    #
    # Each plugin is a `.rb` file that defines a class with a `#call(event)` method.
    # The class name must match the filename (PascalCase):
    #   `my_hook.rb` → `MyHook` class
    #
    # The loader:
    # 1. Loads each plugin file via `require` (absolute path)
    # 2. Instantiates the class
    # 3. Registers a Proc in the given Registry that calls `plugin.call(event)`
    #
    # Plugins are loaded once and cached. The same plugin can be registered
    # for multiple event types by specifying it multiple times in the config.
    #
    # Config format:
    #   hooks:
    #     hooks_dir: "~/my_hooks/"   # default: <config dir>/hooks/, next to config.yml
    #     before_turn:
    #       - path: "my_hook.rb"
    #         on_error: skip  # or "log"
    #       - path: "another.rb"
    #
    # The loader creates a `Hooks::Registry` instance, loads plugins, and
    # registers each plugin's `call` method as a Proc under the specified event name.
    class Loader
      class << self
        # $XDG_CONFIG_HOME/samagotchi/hooks/ or ~/.config/samagotchi/hooks/.
        def default_hooks_dir(env = ENV)
          File.join(ConfigFile.config_dir(env: env), "hooks", "")
        end

        # Load hooks from a config hash and return a Registry with registered plugins.
        #
        # @param config_hash [Hash, nil] the hooks section from config.yml
        # @param env [Hash] environment variables (default: ENV)
        # @return [Samagotchi::Hooks::Registry] the registry with all plugins registered
        def load(config_hash, env: ENV)
          return Hooks::Registry.new unless config_hash&.key?("hooks")

          hooks_config = config_hash["hooks"]
          hooks_dir = expand_path(hooks_config["hooks_dir"] || default_hooks_dir(env), env)

          registry = Hooks::Registry.new
          definitions = parse_definitions(hooks_config)

          definitions.each do |defn|
            begin
              plugin = load_plugin(hooks_dir, defn[:path])
              # Register a Proc that calls plugin.call(event)
              # Wrap in begin/rescue to handle plugins that don't respond_to :call
              # Persistent: config hooks must fire on every turn, not be wiped
              # by Engine#run_turn's per-turn clear_hooks after turn 1.
              registry.register_persistent(defn[:event_type].to_sym) do |event|
                begin
                  plugin.call(event)
                rescue StandardError => e
                  handle_error(defn[:on_error] || "skip", defn[:path], e)
                end
              end
            rescue LoadError, StandardError => e
              warn "DEBUG: Hook load failed for #{defn[:path]}: #{e.class}: #{e.message}"
              handle_error(defn[:on_error] || "skip", defn[:path], e)
            end
          end

          registry
        end
      end

      # Expand a path that may start with ~.
      def self.expand_path(path, env = ENV)
        return path unless path.start_with?("~")
        home = env["HOME"] || Dir.home
        File.join(home, path[1..])
      end

      # Parse hook definitions from the config hooks section.
      # Returns an array of { event_type:, path:, on_error: } hashes.
      def self.parse_definitions(hooks_config)
        definitions = []
        hooks_config.each do |event_type, configs|
          next unless event_type.to_s != "hooks_dir" && configs.is_a?(Array)
          configs.each do |cfg|
            next unless cfg.is_a?(Hash) && cfg["path"]
            definitions << {
              event_type: event_type.to_s,
              path: cfg["path"],
              on_error: (cfg["on_error"] || "skip").to_s
            }
          end
        end
        definitions
      end

      # Load a plugin from the hooks directory.
      # Returns an instance of the plugin class.
      def self.load_plugin(hooks_dir, path)
        full_path = File.expand_path(File.join(hooks_dir, path))

        # Check if already loaded (Ruby's require caching handles this)
        # We cache the instance separately to avoid re-instantiating
        unless @plugin_cache
          @plugin_cache = {}
        end

        @plugin_cache[full_path] ||= begin
          require full_path
          class_name = File.basename(path, ".rb").split("_").map(&:capitalize).join
          klass = Object.const_get(class_name)
          instance = klass.new
          # Validate that the instance responds to #call
          raise ArgumentError, "Plugin #{class_name} does not respond to #call" unless instance.respond_to?(:call)
          instance
        end
      end

      # Handle a hook error based on the on_error config.
      def self.handle_error(on_error, hook_path, error = nil)
        case on_error
        when "log"
          warn "[samagotchi:hook] #{error ? "#{error.class}: #{error.message}" : "hook failed"} (#{hook_path})"
        when "skip"
          # Silent — just skip
        end
      end
    end
  end
end
