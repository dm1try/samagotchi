# frozen_string_literal: true

require "yaml"
require_relative "version"
require_relative "config"

module Samagotchi
  # A session's own settings (chi --set, chi send --new --set, POST
  # /api/sessions settings), kept as one value (Settings). Its core part:
  # {key => value} for the core config keys a session may set
  # (Config::Entry#session?), typed by their entry (Config.coerce!) and
  # read through Config.get(key, session:) by the readers wired to it
  # (RecapSetup). Its
  # bundles part: {bundle => {key => value}}, string keys, scalar values
  # (.typed). A bundle offers the keys a session may set in its manifest's
  # session_settings: (recorded at install, InstalledBundle#session_settings);
  # any other bundle or key is refused, so a typo isn't saved, and so is a
  # value of another type than the manifest gives the key (session_settings:
  # {cap: number}). The session keeps them (Session#settings, SessionSetup)
  # and Plugin::Context#settings lays them over config.yml's bundles: <name>:.
  module SessionConfig
    # A refused --set (or request field): the message says why.
    class Error < ArgumentError; end

    # A bundle name (MemoryBundle::Manifest::BUNDLE_NAME) and a setting key.
    BUNDLE = /\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
    KEY = /\A[A-Za-z0-9_][A-Za-z0-9_-]*\z/
    # The values a setting may take.
    SCALARS = [String, Integer, Float, TrueClass, FalseClass].freeze
    REQUEST_SHAPE = "settings is an object of KEY or BUNDLE.KEY => scalar"
    # What --set takes, as a malformed one is told.
    FORMS = "KEY=VALUE or BUNDLE.KEY=VALUE"
    # What .typed reads as a number: no leading zero, no _; a decimal may
    # leave out either side of its point (.5, 5.) and take an exponent
    # (1e1, 2.5e-3), which YAML 1.1 leaves as text.
    INTEGER = /\A-?(?:0|[1-9]\d*)\z/
    DECIMAL = /\A-?(?:(?:0|[1-9]\d*)(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?\z/
    # YAML 1.1's booleans (config.yml's), any case.
    TRUE_WORDS = %w[true yes on].freeze
    FALSE_WORDS = %w[false no off].freeze
    # The shipped bundles' sources (a stale record's hint reads them).
    SHIPPED_DIR = File.expand_path("bundles", __dir__)

    # A session's own settings, as one value: +core+ its core config keys
    # ({key => value}, .normalize_core's shape), +bundles+ its bundle
    # settings ({bundle => {key => value}}, .normalize's shape). Both
    # frozen, string keys; the session file keeps +core+ under
    # config_settings and +bundles+ under bundle_settings.
    Settings = Data.define(:core, :bundles) do
      def initialize(core: {}, bundles: {})
        super(core: SessionConfig.normalize_core(core), bundles: SessionConfig.normalize(bundles))
      end

      # A Settings as given, nil as none (EMPTY).
      # @param value [Settings, nil]
      # @return [Settings]
      # @raise [ArgumentError] anything else
      def self.of(value)
        return value if value.is_a?(Settings)
        return Settings::EMPTY if value.nil?

        raise ArgumentError, "session settings are a SessionConfig::Settings, not #{value.class}"
      end

      def empty? = core.empty? && bundles.empty?

      # Both parts as --set names them: {"recap.enabled" => false,
      # "cost-cap.cap" => 3} (/stats, chi sessions stats --format json).
      # @return [Hash{String => Object}]
      def flat
        core.merge(bundles.flat_map { |bundle, values| values.map { |key, value| ["#{bundle}.#{key}", value] } }.to_h)
      end

      # "recap.enabled=false · cost-cap.cap=3", "" for none.
      def text = SessionConfig.text(flat)
    end

    # The installed bundles a session may set settings of: +offered+ the
    # keys of each bundle whose plugin loads ({name => keys}), +notes+ what
    # a refusal adds for a bundle ({name => text}): why its plugin doesn't
    # load, or how to refresh a record from before session_settings;
    # +types+ the types its manifest gives keys ({name => {key => type}}).
    Availability = Data.define(:offered, :notes, :types) do
      def initialize(offered:, notes:, types: {}) = super
    end

    # What each type (MemoryBundle::Manifest::SESSION_SETTING_TYPES) takes,
    # as a value .typed gives it, and how a refusal names it. A number may
    # be off (false), as a bundle's own settings are turned off.
    TYPES = {
      "number" => [->(value) { (value.is_a?(Numeric) && value.finite?) || value == false }, "a number (or off)"],
      "boolean" => [->(value) { [true, false].include?(value) }, "true or false"],
      "string" => [->(value) { value.is_a?(String) }, "text"]
    }.freeze

    module_function

    # --set's values as typed, in order: a later one of the same key wins.
    # A name a core config entry has (recap.enabled), or one with no dot,
    # is a core key (.core_value: a session-settable one, typed by its
    # entry); any other is BUNDLE.KEY, its value .typed (a key +types+
    # gives as string keeps its text as given, .value_for).
    # @param args [Array<String>] "KEY=VALUE" or "BUNDLE.KEY=VALUE" each
    # @param types [Hash{String => Hash{String => String}}] Availability#types
    # @param bundles [Hash, nil] the offered keys an unknown dotless key's
    #   refusal names (.offered by default)
    # @return [Settings]
    # @raise [Error] a value of another shape, a core key no session sets
    def parse(args, types: {}, bundles: nil)
      core = {}
      given = {}
      Array(args).each do |arg|
        target, sep, raw = arg.to_s.partition("=")
        raise Error, "--set takes #{FORMS}, not #{arg}" if sep.empty?

        name = split(target, "--set #{arg}") { raise Error, "--set takes #{FORMS}, not #{arg}" }
        raise Error, "--set #{arg}: give a value" if raw.strip.empty?

        if name.is_a?(String)
          core[name] = core_value(name, raw, flag: "--set", bundles: bundles)
        else
          bundle, key = name
          (given[bundle] ||= {})[key] = value_for(raw, types.dig(bundle, key))
        end
      end
      Settings.new(core: core, bundles: given)
    end

    # +target+ (the part before =) as a core key (a String) or [bundle,
    # key]; yields when it is no name at all.
    def split(target, where)
      return target if Config.find_by_key(target)

      bundle, *keys = target.split(".", -1)
      yield if keys.empty? ? !KEY.match?(bundle.to_s) : !BUNDLE.match?(bundle.to_s) || keys.any? { |key| !KEY.match?(key) }
      return target if keys.empty?
      raise Error, "#{where}: one key under the bundle (BUNDLE.KEY), no nested path" if keys.size > 1

      [bundle, keys.first]
    end

    # A core key's value: +key+ names a session-settable entry, and +raw+
    # types as it (Config.coerce!) and passes its check:.
    # @raise [Error] "FLAG KEY: why"
    def core_value(key, raw, flag:, bundles: nil)
      entry = Config.find_by_key(key)
      raise Error, "#{flag} #{key}: #{unknown_core(key, bundles: bundles)}" unless entry
      raise Error, "#{flag} #{key}: #{key} is not a session setting (#{settable_text})" unless entry.session?

      value = begin
        Config.coerce!(entry, raw)
      rescue Error => e
        raise Error, "#{flag} #{key}: #{e.message}"
      end
      if (takes = entry.check&.call(value))
        raise Error, "#{flag} #{key}: #{key} takes #{takes}, not #{raw.to_s.inspect}"
      end

      value
    end

    # Why +key+ (no config entry) is no session setting, with the settable
    # keys it is near; a dotless or non-core-section key also names the
    # bundles that take --set (it may have meant one).
    def unknown_core(key, bundles: nil)
      near = Config.near_names(key, Config.session_entries.map(&:key))
      hint = near.empty? ? settable_text : "did you mean #{near.join(" or ")}?"
      hint = "#{hint}; #{takers(bundles || offered)}" unless core_section?(key.split(".").first)
      "no session setting #{key} (#{hint})"
    end

    # "session settings: recap.enabled, recap.sentences"
    def settable_text = "session settings: #{Config.session_entries.map(&:key).join(", ")}"

    # Whether +name+ is a core config section (recap, guardrails).
    def core_section?(name) = Config::ENTRIES.any? { |entry| entry.yaml_path.size > 1 && entry.section == name }

    # +settings+ (a Settings, or its bundles part) when every bundle is
    # installed and offers each key; a bundle that isn't installed but
    # names a core section (recap.enable) is a core key no session sets.
    # Its core part was checked as it was typed (.parse, .from_request).
    # @param bundles [Hash{String => Array<String>}] the installed bundles'
    #   offered keys (.offered)
    # @param notes [Hash{String => String}] Availability#notes
    # @param types [Hash{String => Hash{String => String}}] Availability#types:
    #   a typed key's value must be of its type (TYPES)
    # @param flag [String] what a refusal names ("--set", a request field)
    # @return [Settings, Hash] +settings+
    # @raise [Error]
    def check!(settings, bundles: offered, notes: {}, types: {}, flag: "--set")
      (settings.is_a?(Settings) ? settings.bundles : settings).each do |bundle, values|
        keys = bundles[bundle]
        note = notes[bundle]
        values.each do |key, value|
          where = "#{flag} #{bundle}.#{key}"
          if keys.nil?
            raise Error, "#{where}: #{unknown_core("#{bundle}.#{key}", bundles: bundles)}" if note.nil? && core_section?(bundle)

            raise Error, "#{where}: #{note || "no installed bundle #{bundle} (#{takers(bundles)})"}"
          end
          raise Error, "#{where}: #{bundle} takes no session settings#{" #{note}" if note}" if keys.empty?
          raise Error, "#{where}: #{bundle} takes #{keys.join(", ")}" unless keys.include?(key)

          takes, what = TYPES[types.dig(bundle, key)]
          raise Error, "#{where}: #{bundle} takes #{what} for #{key}, not #{value.inspect}" if takes && !takes.call(value)
        end
      end
      settings
    end

    # --set's values parsed and checked (.parse, .check!) against the
    # installed bundles (.availability).
    # @return [Settings]
    def from_flags(args, available: availability)
      check!(parse(args, types: available.types, bundles: available.offered), bundles: available.offered, notes: available.notes, types: available.types)
    end

    # A value as --set (and a request's string) gives it: an integer
    # ("3", "-1"), a decimal ("2.5", ".5", "1e1"), a boolean as config.yml's
    # YAML reads one (true/yes/on, false/no/off, any case); any other string
    # stays as given ("010", "0x10", "3:30", "y", "null"). A value that
    # isn't a String (a JSON number or boolean) is kept.
    def typed(value)
      return value unless value.is_a?(String)
      return Integer(value, 10) if INTEGER.match?(value)

      if DECIMAL.match?(value)
        number = Float(float_text(value))
        # 1e400 is Infinity: no cap reaches it and JSON can't save it.
        return number.finite? ? number : value
      end

      word = value.downcase
      return true if TRUE_WORDS.include?(word)
      return false if FALSE_WORDS.include?(word)

      value
    end

    # A value for a key of +type+: a string key's text as given (--set
    # b.name=yes stays "yes"), any other's .typed.
    def value_for(value, type) = type == "string" ? value : typed(value)

    # A decimal DECIMAL matches as Float reads it on every Ruby: a point
    # with no digit after it ("5.", "5.e1") gets a 0, which Ruby 3.3's
    # Float wants.
    def float_text(value) = value.sub(/\.(?=e|\z)/i, ".0")

    # POST /api/sessions settings: nil for none, else an object of names
    # as --set gives them (KEY or BUNDLE.KEY) to scalars (a string typed as
    # --set types it), checked like --set.
    # @param bundles [Hash, nil] the offered keys (.availability's by default)
    # @param types [Hash] their types, with +bundles+ (Availability#types)
    # @return [Settings]
    # @raise [Error]
    def from_request(raw, bundles: nil, types: {})
      return Settings::EMPTY if raw.nil?
      raise Error, REQUEST_SHAPE unless raw.is_a?(Hash) && scalar_map?(raw)
      return Settings::EMPTY if raw.empty?

      available = bundles ? Availability.new(offered: bundles, notes: {}, types: types) : availability
      core = {}
      given = {}
      raw.each do |target, value|
        target = target.to_s
        name = split(target, "settings #{target}") { raise Error, "settings takes KEY or BUNDLE.KEY names, not #{target.inspect}" }
        raise Error, "settings #{target}: give a value" if value.is_a?(String) && value.strip.empty?

        if name.is_a?(String)
          core[name] = core_value(name, value, flag: "settings", bundles: available.offered)
        else
          bundle, key = name
          (given[bundle] ||= {})[key] = value_for(value, available.types.dig(bundle, key))
        end
      end
      check!(Settings.new(core: core, bundles: given), bundles: available.offered, notes: available.notes,
                                                       types: available.types, flag: "settings")
    end

    # Each installed bundle's offered keys, by name (Availability#offered).
    # @return [Hash{String => Array<String>}]
    def offered(dir: nil) = availability(dir: dir).offered

    # The installed bundles a session may set settings of: a record that
    # doesn't read is left out, and so is one whose plugin doesn't load as
    # chi's loader decides (Plugin::Loader#unloadable_reason: requires_chi,
    # the file, its sha256), with a note saying why. A record with no
    # session_settings whose shipped bundle lists some (installed before
    # them) gets a note on refreshing it.
    # @return [Availability]
    def availability(dir: nil, shipped_dir: SHIPPED_DIR)
      require_relative "memory_bundle/provenance"
      require_relative "memory_bundle/manifest"
      dir ||= MemoryBundle::Provenance.bundles_dir
      offered = {}
      notes = {}
      types = {}
      MemoryBundle::Provenance.each_installed(dir: dir) do |name, bundle|
        next if bundle.error?

        if (reason = unloadable(dir, name, bundle))
          notes[name] = "#{name} is installed but its plugin doesn't load: #{reason}"
          next
        end
        offered[name] = bundle.session_settings
        types[name] = bundle.session_setting_types unless bundle.session_setting_types.empty?
        if bundle.session_settings.empty? && shipped_settings?(shipped_dir, name)
          notes[name] = "(run `chi update` or `chi bundle upgrade #{name}` to refresh it)"
        end
      end
      Availability.new(offered: offered, notes: notes, types: types)
    end

    # A session file's value, read tolerantly: the bundles that map to
    # settings, the scalar ones of those, string keys, frozen; {} for
    # anything else.
    # @return [Hash{String => Hash{String => Object}}]
    def normalize(raw)
      return {}.freeze unless raw.is_a?(Hash)

      deep_freeze(raw.each_with_object({}) do |(bundle, values), acc|
        next unless values.is_a?(Hash)

        kept = values.each_with_object({}) do |(key, value), scalars|
          scalars[key.to_s] = value if SCALARS.any? { |kind| value.is_a?(kind) }
        end
        acc[bundle.to_s] = kept unless kept.empty?
      end)
    end

    # Settings#core read tolerantly: the session-settable keys
    # (Config::Entry#session?) whose value types as their entry and passes
    # its check:, typed, string keys, frozen; {} for anything else (a key
    # that is no longer settable, a hand-edited value).
    # @return [Hash{String => Object}]
    def normalize_core(raw)
      return {}.freeze unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, value), kept|
        entry = Config.find_by_key(key.to_s)
        next unless entry&.session? && SCALARS.any? { |kind| value.is_a?(kind) }

        typed = begin
          Config.coerce!(entry, value)
        rescue Error
          next
        end
        next if typed.nil? || entry.check&.call(typed)

        kept[entry.key] = typed.frozen? ? typed : typed.dup.freeze
      end.freeze
    end

    # "KEY=VALUE · KEY=VALUE" for {key => value} (Settings#flat), "" for none.
    def text(flat) = flat.map { |key, value| "#{key}=#{value}" }.join(" · ")

    # Why a bundle +name+ can't offer the session settings +keys+: one
    # whose NAME.KEY is a session-settable core key (--set NAME.KEY sets
    # chi's), nil when none clashes. The install refuses it and chi bundle
    # check reports it (clash), in these words.
    # @return [String, nil]
    def clash(name, keys)
      clashing = Array(keys).map { |key| "#{name}.#{key}" } & Config.session_entries.map(&:key)
      return nil if clashing.empty?

      "session_settings: #{clashing.join(", ")} #{clashing.size == 1 ? "is" : "are"} chi's own session " \
        "setting#{"s" unless clashing.size == 1} (--set #{clashing.first}=… sets chi's); rename the setting or the bundle"
    end

    # Why +bundle+'s plugin doesn't load, as chi's loader decides it
    # (Plugin::Loader.unloadable_reason), nil when it does or has none.
    def unloadable(dir, name, bundle)
      return nil unless bundle.plugin

      require_relative "plugin/loader"
      # +dir+, not Provenance#plugin_path's bundles_dir: a spec's records live elsewhere.
      Plugin::Loader.unloadable_reason(File.join(dir, name, "plugin", bundle.plugin.file.to_s), bundle)
    end

    # Whether chi ships a bundle +name+ whose manifest lists session_settings.
    def shipped_settings?(shipped_dir, name)
      path = File.join(shipped_dir, name, "manifest.yml")
      return false unless File.file?(path)

      raw = YAML.safe_load_file(path)
      listed = raw.is_a?(Hash) ? raw["session_settings"] : nil
      (listed.is_a?(Array) || listed.is_a?(Hash)) && !listed.empty?
    rescue Psych::Exception, SystemCallError
      false
    end

    def scalar_map?(values)
      values.is_a?(Hash) && values.values.all? { |value| SCALARS.any? { |kind| value.is_a?(kind) } }
    end

    def takers(bundles)
      names = bundles.reject { |_, keys| keys.empty? }.keys.sort
      names.empty? ? "no installed bundle takes --set" : "bundles that take --set: #{names.join(", ")}"
    end

    def deep_freeze(settings)
      settings.to_h { |bundle, values| [bundle.dup.freeze, values.to_h { |k, v| [k.dup.freeze, v.frozen? ? v : v.dup.freeze] }.freeze] }.freeze
    end

    private_class_method :unloadable, :shipped_settings?, :scalar_map?, :takers, :deep_freeze, :split, :unknown_core,
                         :settable_text, :core_section?

    # No settings (built once the module's functions are defined).
    Settings::EMPTY = Settings.new
  end
end
