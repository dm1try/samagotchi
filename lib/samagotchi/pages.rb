# frozen_string_literal: true

require "json"
require "digest"
require "time"
require_relative "inline_widgets"
require_relative "paths"
require_relative "atomic_file"

module Samagotchi
  # Pages: a Ruby script under <config>/samagotchi/pages/NAME.rb says what to
  # show (`page "Title" do |ui| ui.text …; ui.table …; ui.walk … end`); a run
  # stores the blocks it built as JSON under <state>/samagotchi/pages/NAME/,
  # and what shows a page draws from that file (docs/pages.md,
  # docs/internals/pages.md).
  #
  # Light on purpose: the runner (pages/runner.rb) is a process of its own
  # that requires this file only, so nothing here may require the engine, the
  # config, the web, the plugins or the launcher (pages/launch.rb, which
  # spawns the runner and needs ProcessGroup and ChildEnv). What a script
  # reads of chi (Pages::Runtime) requires its own code when called, never
  # at load (spec/pages_runtime_spec.rb runs a page to check).
  module Pages
    autoload :Builder, File.expand_path("pages/builder", __dir__)
    autoload :TableBlock, File.expand_path("pages/builder", __dir__)
    autoload :Store, File.expand_path("pages/store", __dir__)
    autoload :Runtime, File.expand_path("pages/runtime", __dir__)
    autoload :Bundled, File.expand_path("pages/bundled", __dir__)

    # A page's name: lowercase letters, digits and hyphens, a letter or a
    # digit first, at most 40.
    NAME = /\A[a-z0-9][a-z0-9-]{0,39}\z/
    MAX_ROWS = 500
    MAX_COLUMNS = 12
    MAX_CELL = 300
    MAX_BLOCKS = 20
    MAX_TEXT_BYTES = 16 * 1024
    MAX_OUTPUT_BYTES = 256 * 1024
    TIMEOUT_SECONDS = 30
    FORMATS = %i[money count].freeze

    # Anything that keeps a page from running or from being stored. Each
    # subclass owns its message.
    class Error < StandardError; end

    # A rule a script broke (a limit, a table's column, page called twice):
    # the run fails with this message.
    class Refused < Error; end

    # A name that breaks NAME: the command line's fault (exit 2).
    class BadName < Error
      def initialize(name)
        super("#{name.to_s.inspect} isn't a page name (lowercase letters, digits and hyphens, a letter or digit first, at most 40)")
      end
    end

    # No script for the name.
    class Missing < Error
      def initialize(name)
        super("no page #{name}")
      end
    end

    # A remove of a page a bundle ships (Bundled): its script is the
    # bundle's, and the page lasts as long as the bundle does.
    class FromBundle < Error
      def initialize(name, bundle)
        super("page #{name} comes with the #{bundle} bundle: uninstall the bundle or write your own " \
              "#{Paths.tilde(Pages.user_script_path(name))}")
      end
    end

    # Another run (or a remove) holds the page's lock.
    class Busy < Error
      def initialize(name)
        super("page #{name} is already running")
      end
    end

    # A failed run: what the script raised (or why it was stopped), the
    # script's line when one is known, when, and the sha256 of the script
    # that failed.
    Failure = Data.define(:message, :line, :at, :script_sha) do
      def to_json_hash = { "message" => message, "line" => line, "at" => at, "script_sha" => script_sha }
    end

    # A page as stored (Store.read): the blocks of its last good run (none
    # before one, ran_at nil) and the last failure since, if any.
    # +current_sha+ is the script's sha256 now (nil when the script is gone).
    # +bundle+ the bundle whose script it runs (Bundled), nil for the
    # user's own; +script+ the script's path (Pages.script_path).
    Stored = Data.define(:name, :title, :blocks, :ran_at, :duration_ms, :script_sha, :error, :current_sha, :bundle,
                         :script) do
      def initialize(bundle: nil, script: nil, **fields) = super

      # :never_ran, :ok or :failed (the last run failed; the good blocks, if
      # any, are still there).
      def state
        return :failed if error
        return :ok if ran_at

        :never_ran
      end

      # Whether the script differs from the one that made the blocks.
      def changed? = !script_sha.nil? && !current_sha.nil? && current_sha != script_sha

      # The output file's JSON.
      def to_json_hash
        { "name" => name, "title" => title, "blocks" => blocks, "ran_at" => ran_at, "duration_ms" => duration_ms,
          "script_sha" => script_sha, "error" => error&.to_json_hash }
      end
    end

    module_function

    def valid_name?(name) = name.is_a?(String) && NAME.match?(name)

    # The one check every path goes through before it builds a path.
    # @return [String] +name+
    # @raise [BadName]
    def check_name!(name)
      raise BadName, name unless valid_name?(name)

      name
    end

    # @return [String] <config home>/samagotchi/pages (ConfigFile.config_dir
    #   lives in config.rb, which loads far more than a runner may)
    def scripts_dir = File.join(Paths.config_home, Paths::APP_DIR, "pages")

    # @return [String] <state dir>/pages
    def state_dir = File.join(Paths.state_dir, "pages")

    # Where the user's own NAME.rb is (or would be): what a remove deletes.
    def user_script_path(name) = File.join(scripts_dir, "#{check_name!(name)}.rb")

    # The script NAME runs: the user's NAME.rb when there is one, else the
    # page of that name an installed bundle ships (Bundled), else the user's
    # path (no such page). Every read and run resolves here; a remove never
    # does (user_script_path).
    def script_path(name)
      user = user_script_path(name)
      return user if File.file?(user)

      Bundled.find(name)&.path || user
    end

    # Whether NAME is a page: a script of the user's, or a bundle's page,
    # even one whose installed script is gone (its run then fails with the
    # bundle's refusal, Bundled::Page#refusal, rather than "no page").
    def exists?(name) = File.file?(script_path(name)) || !bundled(name).nil?

    # The bundle page NAME runs, nil when the user's NAME.rb shadows it or no
    # bundle ships one.
    # @return [Bundled::Page, nil]
    def bundled(name)
      return nil if File.file?(user_script_path(name))

      Bundled.find(name)
    end
  end
end
