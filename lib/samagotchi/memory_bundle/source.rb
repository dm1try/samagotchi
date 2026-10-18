# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "shellwords"

module Samagotchi
  module MemoryBundle
    # Normalizes a source (directory, zip, tar.gz, etc.) into a plain directory of .md files.
    #
    # Returns [normalized_path, owned] where:
    #   - dir sources:  [dir_path, false]  — caller owns the directory, do NOT delete.
    #   - archive sources: [temp_dir_path, true] — caller must call cleanup(dir).
    class SourceNormalizer
      class UnknownSourceError < StandardError; end

      def self.normalize(source_path)
        return normalize_git(source_path) if git_url?(source_path)

        path = File.expand_path(source_path)
        raise UnknownSourceError, "source does not exist: #{path}" unless File.exist?(path)

        if File.directory?(path)
          return [path, false]
        end

        # Use full lowercase path for compound extensions like .tar.gz
        lower = path.downcase
        if lower.end_with?(".zip")
          normalize_zip(path)
        elsif lower.end_with?(".tar.gz", ".tgz", ".tar")
          normalize_tar(path)
        else
          ext = File.extname(path).downcase
          raise UnknownSourceError, "unsupported source format: #{path} (extension: #{ext})"
        end
      end

      # The bundles shipped with chi (lib/samagotchi/bundles/<name>).
      SHIPPED_DIR = File.expand_path("../bundles", __dir__)
      # The path shape of a shipped dir; #chi_copy? verifies its owner.
      SHIPPED_SOURCE = %r{/lib/samagotchi/bundles/[^/]+/?\z}

      # Whether +source+ is a dir in the running chi's shipped bundles dir.
      def self.chi_copy?(source, shipped_dir: SHIPPED_DIR)
        path = File.realpath(source.to_s)
        File.directory?(path) && File.dirname(path) == File.realpath(shipped_dir)
      rescue SystemCallError
        false
      end

      # A bare name (no path separator) that isn't a path here names a
      # shipped bundle: `chi bundle install guardrails`. A directory or file
      # of that name in the cwd wins.
      # @return [String, nil] the shipped bundle's dir
      def self.shipped_bundle_dir(source, cwd: Dir.pwd)
        name = source.to_s.strip
        return nil unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
        return nil if File.exist?(File.join(cwd, name))

        # Dir.children, not File.file? alone: the name in its exact case
        # (a case-insensitive file system finds btw's dir for BTW).
        return nil unless File.directory?(SHIPPED_DIR) && Dir.children(SHIPPED_DIR).include?(name)

        dir = File.join(SHIPPED_DIR, name)
        File.file?(File.join(dir, "manifest.yml")) ? dir : nil
      end

      def self.git_url?(str)
        s = str.to_s.strip
        return false if s.empty?

        s.match?(%r{\A(?:https?://|git@|ssh://|git://|file://).+})
      end

      def self.strip_git_ref(url)
        if url.include?("#")
          parts = url.split("#", 2)
          [parts[0], parts[1]]
        else
          [url, nil]
        end
      end

      def self.normalize_git(git_url)
        url, ref = strip_git_ref(git_url.strip)
        Dir.mktmpdir("samagotchi-git-") do |clone_parent|
          clone_dir = File.join(clone_parent, "repo")
          args = ["git", "clone", "--depth", "1"]
          args += ["--branch", ref] if ref && !ref.empty?
          args += [url, clone_dir]
          result = system(*args)
          raise UnknownSourceError, "git clone failed for #{git_url}" unless result && File.directory?(clone_dir)

          # Capture HEAD commit before stripping .git (audit trail)
          commit = nil
          begin
            commit = `git -C #{clone_dir.shellescape} rev-parse HEAD 2>/dev/null`.strip
            commit = nil if commit.empty?
          rescue StandardError
            commit = nil
          end
          # Remove .git to avoid leaking
          FileUtils.rm_rf(File.join(clone_dir, ".git"))
          path, owned = clean_copy_of(clone_dir)
          # Thread commit through via extra return value and class accessor for backward compat
          @last_git_commit = commit
          return [path, owned, commit]
        end
      end

      class << self
        attr_accessor :last_git_commit

        def cleanup(dir)
          FileUtils.rm_rf(dir) if dir && File.directory?(dir)
        end
      end

      def self.normalize_zip(zip_path)
        Dir.mktmpdir("samagotchi-zip-") do |extract_dir|
          result = system("unzip", "-o", zip_path, "-d", extract_dir)
          raise UnknownSourceError, "unzip failed for #{zip_path}" unless result

          clean_copy_of(extract_dir)
        end
      end

      def self.normalize_tar(tar_path)
        Dir.mktmpdir("samagotchi-tar-") do |extract_dir|
          is_gz = tar_path.end_with?(".tar.gz", ".tgz")
          cmd = is_gz ? ["tar", "-xzf"] : ["tar", "-xf"]
          result = system(*cmd, tar_path, "-C", extract_dir)
          raise UnknownSourceError, "tar extraction failed for #{tar_path}" unless result

          clean_copy_of(extract_dir)
        end
      end

      # Copies the contents of `src_dir` into a new permanent directory, stripping
      # one level of nesting if there's a single top-level entry.
      # The returned path survives after `src_dir` is cleaned up.
      # A symlink stays a symlink, at the top level too (cp_r dereferences
      # its root by default): the Installer then skips it (MemoryFiles,
      # AssetInstaller#linked?) instead of installing what it points at.
      def self.clean_copy_of(src_dir)
        contents = Dir.entries(src_dir).reject { |e| e.start_with?(".") }
        # Zip-slip check: reject entries with ".." path components.
        contents.each do |entry|
          if entry.include?("..")
            raise UnknownSourceError, "archive contains unsafe path component: #{entry}"
          end
        end

        if contents.size == 1
          entry_path = File.join(src_dir, contents.first)
          if File.directory?(entry_path) && !File.symlink?(entry_path) && !Dir.empty?(entry_path)
            dst = Dir.mktmpdir("samagotchi-bundle-")
            FileUtils.cp_r("#{entry_path}/.", dst, dereference_root: false)
            return [dst, true]
          end
        end

        dst = Dir.mktmpdir("samagotchi-bundle-")
        contents.each do |entry|
          FileUtils.cp_r(File.join(src_dir, entry), dst, dereference_root: false)
        end
        [dst, true]
      end

      private_class_method :normalize_zip, :normalize_tar, :clean_copy_of
    end

    # What a bundle's source is, for telling whether two installs of one
    # name come from the same place (Installer: a bundle from elsewhere
    # doesn't silently replace an installed one). key is
    #   shipped:<dir>  a dir in this chi's shipped bundles, so `chi update`
    #                  and a newer chi upgrade it
    #   git:<url>      a git URL without its #ref, a trailing / or .git
    #   path:<path>    an absolute path, symlinks resolved when it exists
    # .of is nil for a source it can't place (empty, or a relative path an
    # older record may hold): unknown never refuses.
    SourceIdentity = Data.define(:key) do
      def self.of(source)
        s = source.to_s.strip
        return nil if s.empty?

        if SourceNormalizer.git_url?(s)
          url = SourceNormalizer.strip_git_ref(s).first.sub(%r{/+\z}, "").delete_suffix(".git")
          new(key: "git:#{url}")
        elsif s.match?(SourceNormalizer::SHIPPED_SOURCE) && SourceNormalizer.chi_copy?(s)
          new(key: "shipped:#{File.basename(s.chomp("/"))}")
        elsif s.start_with?("/")
          new(key: "path:#{real(s)}")
        end
      end

      # +source+ as a path:<realpath>, whatever it looks like.
      def self.path(source) = new(key: "path:#{real(source.to_s)}")

      def self.real(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end
      private_class_method :real

      def shipped? = key.start_with?("shipped:")

      def to_s = key
    end

    # A source normalized once to a local dir (SourceNormalizer.normalize):
    # owned when it is a git clone or a zip/tar extract, which #cleanup
    # removes; commit is a git clone's HEAD (nil otherwise). BundleCommand
    # reads the bundle's name from it and the Installer installs from it, so
    # a source is cloned or extracted once per command.
    PreparedSource = Data.define(:dir, :owned, :commit) do
      # @raise [SourceNormalizer::UnknownSourceError]
      def self.prepare(source)
        dir, owned, commit = SourceNormalizer.normalize(source)
        new(dir: dir, owned: owned, commit: commit)
      end

      def cleanup
        SourceNormalizer.cleanup(dir) if owned
      end
    end
  end
end
