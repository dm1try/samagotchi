# frozen_string_literal: true

require "fileutils"

module Samagotchi
  module Testing
    # Fake commands for a test's PATH (Sandbox#fake_executable), cheap to
    # exec: macOS checks a new executable file on its first exec (about
    # 0.5–1 s, once per file; minutes on a busy machine). A fake is a
    # symlink to the checked-in launcher, which runs the fake's body
    # (<name>.sh beside the link) with /bin/sh: writing a new body costs
    # nothing.
    module FakeExecutable
      LAUNCHER = File.expand_path("fake_executable_launcher", __dir__)

      module_function

      # Writes +dir+/+name+, which runs +body+ (sh) with its arguments;
      # again for the same name replaces the body.
      # @return [String] the command's path
      def write(dir, name, body)
        FileUtils.mkdir_p(dir)
        path = File.join(dir, name)
        File.write("#{path}.sh", body.end_with?("\n") ? body : "#{body}\n")
        FileUtils.ln_sf(launcher, path)
        path
      end

      def launcher = LAUNCHER
    end
  end
end
