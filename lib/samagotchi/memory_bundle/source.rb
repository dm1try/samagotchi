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
        elsif lower.end_with?(".tar.gz") || lower.end_with?(".tgz") || lower.end_with?(".tar")
          normalize_tar(path)
        else
          ext = File.extname(path).downcase
          raise UnknownSourceError, "unsupported source format: #{path} (extension: #{ext})"
        end
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

      private

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
          if File.directory?(entry_path) && !Dir.empty?(entry_path)
            dst = Dir.mktmpdir("samagotchi-bundle-")
            FileUtils.cp_r("#{entry_path}/.", dst)
            return [dst, true]
          end
        end

        dst = Dir.mktmpdir("samagotchi-bundle-")
        contents.each do |entry|
          FileUtils.cp_r(File.join(src_dir, entry), dst)
        end
        [dst, true]
      end
    end
  end
end
