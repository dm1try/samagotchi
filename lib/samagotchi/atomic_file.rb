# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Samagotchi
  # Replace a file whole: the content goes to a temporary file next to it
  # (<path>.<pid>.<random>.tmp, unique per process and call, so a worker and
  # a CLI writing the same file never share one), which is then renamed over
  # +path+. A reader sees the old file or the new one, never half of one, and
  # two writers racing leave one of the two contents. The temporary name ends
  # in .tmp, so globs for *.json or *.md never list it. On failure it is
  # removed and the error raised; +path+ is left as it was.
  module AtomicFile
    module_function

    # @param path [String] the file to replace (its folder must exist)
    # @param content [String] written as-is, byte for byte
    # @param perm [Integer, nil] the new file's mode; nil = a fresh file's
    #   (0666 less the umask), like File.write
    # @return [String] +path+
    def write(path, content, perm: nil)
      tmp = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, perm || 0o666) do |io|
        io.write(content)
      end
      File.chmod(perm, tmp) if perm
      File.rename(tmp, path)
      path
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end
  end
end
