# frozen_string_literal: true

require "rbconfig"
require_relative "chi_home"
require_relative "chi_shim"
require_relative "config"
require_relative "desktop"
require_relative "home_notice"
require_relative "installed_gem"
require_relative "log_path"
require_relative "paths"
require_relative "project_env"
require_relative "session"
require_relative "version"

module Samagotchi
  # `chi home doctor`'s rows: the chi home (ChiHome) and what should follow
  # it, each one line with a status and what to run. One check each; the
  # text is the condition owner's (ChiHome, HomeNotice, Desktop::MacOS,
  # ChiShim, ProjectEnv) where another surface says the same.
  class HomeDoctor
    # +status+ :ok, :warn (works, not as intended) or :fail (a launch can't
    # boot what it should).
    Row = Data.define(:status, :text) do
      def to_s = "#{status.to_s.ljust(5)} #{text}"
    end

    # What a Gemfile.lock that bundles chi has (a GEM or PATH spec line).
    LOCKED_CHI = /^ {4}samagotchi \(/

    # @param home [ChiHome::Record, nil] home.json's record
    # @param helper [Desktop::MacOS, nil] the desktop helper (nil off macOS)
    # @param sessions [#call] () → [Session] this machine's sessions
    def initialize(home:, env: ENV, cwd: Dir.pwd, gem_spec: InstalledGem.spec, helper: nil,
                   sessions: -> { Session.list(state_dir: Session.default_state_dir(env: env)) },
                   shim_dir: ChiShim.dir(env: env), log_path: LogPath.resolve(env: env),
                   ruby: RbConfig.ruby, gem_dir: Gem.dir)
      @home = home
      @env = env
      @cwd = cwd
      @gem_spec = gem_spec
      @helper = helper
      @sessions = sessions
      @shim_dir = shim_dir
      @log_path = log_path
      @ruby = ruby
      @gem_dir = gem_dir
    end

    # @return [Array<Row>]
    def rows
      list = [home_row]
      if @home && !ChiHome.problem(@home)
        list.concat([running_row, helper_row, sessions_row, shim_row].compact)
      end
      list.concat([gemfile_row, mise_row, project_env_row].compact)
    end

    # The desktop helper chi home doctor checks: this machine's, when it
    # is installed.
    def self.default_helper(env: ENV)
      return nil unless Desktop.supported?

      helper = Desktop::MacOS.new(env: env, register: false)
      File.file?(helper.launch_path) ? helper : nil
    end

    private

    def ok_row(text) = Row.new(status: :ok, text: text)
    def warn_row(text) = Row.new(status: :warn, text: text)
    def fail_row(text) = Row.new(status: :fail, text: text)

    def home_row
      return ok_row("no chi home: each launch uses the Ruby that starts it (chi home set to record one)") unless @home

      if (problem = ChiHome.problem(@home))
        return fail_row("#{problem}: after a Ruby upgrade, gem install samagotchi with the new Ruby, then " \
                    "chi home set from it (chi home set --ruby PATH); until then launches use the Ruby that starts them")
      end

      ok_row("chi home #{@home.ruby} runs chi #{@home.newest_version}")
    end

    def running_row
      return ok_row("this chi runs from a source checkout: it starts its own code, not the home") unless @gem_spec

      text = HomeNotice.mismatch(@home, ruby: @ruby, gem_dir: @gem_dir)
      text && warn_row("#{text}: launches boot the home; chi home set makes this chi the home")
    end

    def helper_row
      return nil unless @helper

      if (problem = @helper.launch_problem)
        fail_row(problem)
      elsif (problem = @helper.home_problem(@home))
        warn_row(problem)
      end
    end

    # Sessions last saved by a newer chi than the home's: their workers
    # (the home's chi) run them without what that chi added.
    def sessions_row
      newest = @home.newest_version
      newer = @sessions.call.filter_map do |session|
        version = session.written_by
        Gem::Version.new(version) if version.is_a?(String) && Gem::Version.correct?(version)
      end.select { |version| version > newest }
      return nil if newer.empty?

      count = newer.size == 1 ? "1 session was" : "#{newer.size} sessions were"
      warn_row("#{count} last saved by a newer chi (#{newer.max}) than the home's #{newest}: " \
           "their workers run without what it added; chi update brings the home up to date")
    end

    def shim_row
      problem = ChiShim.problem(@home, dir: @shim_dir)
      problem && warn_row(problem)
    end

    # The cwd's project bundling chi (a Gemfile.lock with samagotchi):
    # `bundle exec chi` there runs the bundle's chi, off the home.
    def gemfile_row
      lock = project_lockfile
      return nil unless lock && File.read(lock).match?(LOCKED_CHI)

      warn_row("#{Paths.tilde(lock)} bundles samagotchi: chi under the project's bundle (bundle exec chi) isn't " \
           "supported; run chi itself, and bundle remove samagotchi there")
    rescue SystemCallError
      nil
    end

    # The nearest Gemfile.lock from the cwd up to its git root; nil for
    # chi's own source tree (its gemspec is next to it).
    def project_lockfile
      dir = project_dirs.find { |candidate| File.file?(File.join(candidate, "Gemfile.lock")) }
      return nil if dir.nil? || File.file?(File.join(dir, "samagotchi.gemspec"))

      File.join(dir, "Gemfile.lock")
    end

    # The cwd and the folders above it up to its git root (the cwd alone
    # outside git).
    def project_dirs
      @project_dirs ||= begin
        dirs = []
        dir = File.expand_path(@cwd)
        loop do
          dirs << dir
          break if File.exist?(File.join(dir, ".git"))

          parent = File.dirname(dir)
          break dirs = [dirs.first] if parent == dir

          dir = parent
        end
        dirs
      end
    end

    def mise_row
      mode, origin = Config.get_with_origin("session.project_env")
      return ok_row("project env off (session.project_env: off): tools keep the env of whoever starts the worker") if mode.to_s == "off"

      mise = ProjectEnv.find_mise(env: @env)
      return ok_row("project env: mise (#{mise})") if mise

      origin == :default ? ok_row(ProjectEnv::NO_MISE) : warn_row(ProjectEnv::NO_MISE)
    end

    def project_env_row
      warning = ProjectEnv.last_warning(project_dirs, log_path: @log_path)
      warning && warn_row(warning.message)
    end
  end
end
