# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Fake commands (a `gh`, a `git`) for a spec's PATH, cheap to exec.
#
# macOS checks a new executable file on its first exec: about 0.5–1 s per
# file, once (later execs of that file, even after a rewrite, are fast).
# A spec writing a fresh `#!/bin/sh` script per example pays that every
# time. A fake made here is a symlink to one launcher, made once per
# process, which runs the fake's body (<name>.sh beside the link) with
# /bin/sh: reading a new file costs nothing, only exec'ing one does.
module FakeExecutables
  LAUNCHER = "#!/bin/sh\nexec /bin/sh \"$0.sh\" \"$@\"\n"

  module_function

  # Writes +dir+/+name+: runs +body+ (sh) with the command's arguments.
  # Again for the same name replaces the body.
  # @return [String] the command's path
  def fake_executable(dir, name, body)
    path = File.join(dir, name)
    File.write("#{path}.sh", body.end_with?("\n") ? body : "#{body}\n")
    FileUtils.ln_sf(launcher, path)
    path
  end

  # The body a fake runs (what #fake_executable wrote).
  def fake_executable_body(dir, name) = File.read(File.join(dir, "#{name}.sh"))

  # +dest+ as a copy of the executable +source+ (a script a spec runs from
  # a temp checkout): a hard link to one copy per process, so a run of it
  # costs no first-exec check after the first. Never write through +dest+.
  # @return [String] dest
  def copy_executable(source, dest)
    @copies ||= {}
    copy = @copies[source] ||= File.join(scratch_dir, "copy-#{@copies.size}-#{File.basename(source)}").tap do |path|
      FileUtils.cp(source, path)
      File.chmod(File.stat(source).mode & 0o777, path)
    end
    FileUtils.ln(copy, dest)
    dest
  rescue Errno::EXDEV
    FileUtils.cp(source, dest)
    dest
  end

  def launcher
    @launcher ||= File.join(scratch_dir, "launcher").tap do |path|
      File.write(path, LAUNCHER)
      File.chmod(0o755, path)
    end
  end

  def scratch_dir
    @scratch_dir ||= Dir.mktmpdir("spec-fake-exec").tap do |dir|
      owner = Process.pid
      at_exit { FileUtils.rm_rf(dir) if Process.pid == owner }
    end
  end
end
