# frozen_string_literal: true

require "fileutils"
require "tmpdir"

module Samagotchi
  module Testing
    # Fake commands for a test's PATH (Sandbox#fake_executable), cheap to
    # exec: macOS checks a new executable file on its first exec (about
    # 0.5–1 s, once per file). A fake is a symlink to one launcher, made
    # once per process, that runs the fake's body (<name>.sh beside the
    # link) with /bin/sh: writing a new body costs nothing.
    module FakeExecutable
      LAUNCHER = "#!/bin/sh\nexec /bin/sh \"$0.sh\" \"$@\"\n"

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

      def launcher
        @launcher ||= begin
          dir = Dir.mktmpdir("chi-fake-exec")
          owner = Process.pid
          at_exit { FileUtils.rm_rf(dir) if Process.pid == owner }
          File.join(dir, "launcher").tap do |path|
            File.write(path, LAUNCHER)
            File.chmod(0o755, path)
          end
        end
      end
    end
  end
end
