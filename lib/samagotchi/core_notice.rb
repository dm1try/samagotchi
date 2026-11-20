# frozen_string_literal: true

require "fileutils"
require_relative "bundle_manifest"
require_relative "installed_bundles"
require_relative "log"
require_relative "paths"

module Samagotchi
  # A first session's reminder when none of the core profile's members is installed.
  module CoreNotice
    STAMP_FILE = "core_noticed"
    LINE = "chi: the core safety bundles (loop-guard, guardrails, cost-cap…) aren't installed: chi bundle install core"
    CORE_DIR = File.join(__dir__, "bundles", "core")

    module_function

    def show(env: ENV, io: $stderr)
      return if env["SAMAGOTCHI_CORE_NOTICE"] == "off" || env.key?("SAMAGOTCHI_PROJECT_ENV")

      stamp = File.join(Paths.state_dir(env: env), STAMP_FILE)
      return if File.exist?(stamp)

      members = BundleManifest.read(dir: CORE_DIR).includes
      installed = InstalledBundles.each(dir: MemoryPaths.bundles_dir(env: env)).any? { |name, _| members.include?(name) }
      return if installed

      FileUtils.mkdir_p(File.dirname(stamp))
      File.open(stamp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        io.puts(LINE)
        file.write("shown\n")
      rescue StandardError
        File.unlink(stamp)
        raise
      end
      LINE
    rescue Errno::EEXIST
      nil
    rescue StandardError => e
      Log.warn(:turn, "core_notice_failed", error: e.class.name, msg: e.message)
      nil
    end
  end
end
