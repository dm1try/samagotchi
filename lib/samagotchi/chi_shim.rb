# frozen_string_literal: true

require "fileutils"
require "shellwords"
require_relative "atomic_file"
require_relative "chi_home"
require_relative "log"
require_relative "paths"

module Samagotchi
  # The `chi` a worker's tools run: $XDG_STATE_HOME/samagotchi/bin/chi, a
  # shell script that execs the chi home's Ruby with its boot
  # (ChiHome::Record#boot_argv, CHI_BOOT). ProjectEnv puts its dir first on
  # the worker's PATH, so after the project env (whose PATH would find the
  # project Ruby's chi, an old one or none) an agent's `chi send`, `chi self`
  # or `chi answer` still runs the home's chi. The dir holds `chi` only: the
  # project's ruby, gem and bundle stay the project's; bin/chi, a checkout
  # path or `bundle exec chi` stay themselves.
  module ChiShim
    NAME = "chi"
    HEADER = "# chi's own chi for its tools (ChiShim): rewritten at each worker start from the chi home.\n"
    # A project's RUBYOPT/RUBYLIB/RUBYGEMS_GEMDEPS/GEMRC/BUNDLE_* (a `bundle
    # exec` the tool runs under, a mise [env]) would load the project's gems
    # or settings into the home's chi, its LD_*/DYLD_* libraries into its
    # ruby: unset before the exec.
    UNSET = "unset RUBYOPT RUBYLIB RUBYGEMS_GEMDEPS GEMRC LD_PRELOAD LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES " \
            "DYLD_LIBRARY_PATH\n" \
            "for v in $(/usr/bin/env | /usr/bin/sed -n 's/^\\(BUNDLE[A-Za-z0-9_]*\\)=.*/\\1/p'); do unset \"$v\"; done\n"

    module_function

    # @return [String] $XDG_STATE_HOME/samagotchi/bin
    def dir(env: ENV) = File.join(Paths.state_dir(env: env), "bin")

    def path(dir: self.dir) = File.join(dir, NAME)

    # The script for +home+.
    # @param home [ChiHome::Record]
    def content(home)
      argv = home.boot_argv(run: ChiHome::CHI_BOOT) + ["--"]
      "#!/bin/sh\n#{HEADER}#{UNSET}exec #{argv.map { |arg| Shellwords.escape(arg) }.join(" ")} \"$@\"\n"
    end

    # Writes the shim for +home+ unless it is already that (atomically: a
    # tool running `chi` meanwhile gets the old one or the new one).
    # @return [Boolean] whether the shim is there and current
    def ensure!(home, dir: self.dir)
      file = path(dir: dir)
      want = content(home)
      return true if current?(file, want)

      FileUtils.mkdir_p(dir)
      AtomicFile.write(file, want, perm: 0o755)
      true
    rescue SystemCallError => e
      Log.warn(:worker, "chi_shim_failed", path: file, error: e.class.name, msg: e.message)
      false
    end

    # Why the shim isn't +home+'s (chi home doctor), or nil: nil too
    # without one (the first worker start writes it).
    # @return [String, nil]
    def problem(home, dir: self.dir)
      file = path(dir: dir)
      return nil if !File.exist?(file) || current?(file, content(home))

      "the chi script tools run (#{Paths.tilde(file)}) boots another chi than the home: " \
        "the next worker start rewrites it (chi sessions restart ID for a running session)"
    end

    def current?(file, want)
      File.file?(file) && File.executable?(file) && File.read(file) == want
    rescue SystemCallError
      false
    end
  end
end
