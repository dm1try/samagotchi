# frozen_string_literal: true

require_relative "config"

module Samagotchi
  # How long a message sent as a cut waits for the generation it came during:
  # the seconds a generation must have streamed only thinking before a cut may
  # land (SteerCut), one per model, host or run, like Thinking for the level.
  #
  # Order (#resolve): the env (SAMAGOTCHI_STEER_CUT_AFTER), then
  # models.<key>.steer_cut_after, hosts.<name>.steer_cut_after,
  # steer.cut_after in config.yml, then 20. 0 = never cut (a slow local
  # thinker is left alone); it is a value, not an unset.
  module SteerCutAfter
    KEY = "steer_cut_after"
    ENV_KEY = "SAMAGOTCHI_STEER_CUT_AFTER"
    DEFAULT = 20

    module_function

    # A `steer_cut_after:` setting (hosts: entry or models: entry): whole
    # seconds ≥ 0 (0 = never), nil when unset; anything else warns once,
    # naming +where+, and counts as unset.
    # @return [Integer, nil]
    def seconds(value, where)
      return nil if value.nil?

      text = value.to_s.strip
      return text.to_i if text.match?(/\A\d+\z/)

      ConfigFile.warn_once "Warning: #{where}: steer_cut_after must be whole seconds (0 = never); ignored"
      nil
    end

    # The seconds for +target+ and where they came from
    # ("SAMAGOTCHI_STEER_CUT_AFTER", "models: qwen", "hosts.splash",
    # "steer.cut_after"; nil for the default).
    # @param target [HostRegistry::ModelTarget]
    # @param names [Array<String>] the model's lookup names (HostRegistry#lookup_names)
    # @param models [Hash{String => ModelSettings}, nil] ConfigFile.model_settings (specs)
    # @return [Array(Integer, String|nil)]
    def resolve(target, names:, models: nil)
      value, origin = Config.get_with_origin("steer.cut_after")
      return [value.to_i, ENV_KEY] if origin == :env

      models ||= begin
        ConfigFile.model_settings
      rescue StandardError
        {}
      end
      setting = ConfigFile.model_setting(names, :steer_cut_after, models: models)
      return [setting.value, "models: #{setting.key}"] if setting

      host = target.entry.steer_cut_after
      return [host, "hosts.#{target.entry.name}"] unless host.nil?

      return [value.to_i, "steer.cut_after"] if origin == :file

      [DEFAULT, nil]
    end

    # "after 60 s (models: qwen)"; 0 or less is "never (hosts.splash)".
    # No source: just the seconds.
    def label(seconds, source)
      text = seconds.to_i <= 0 ? "never" : "after #{seconds} s"
      source ? "#{text} (#{source})" : text
    end
  end
end
