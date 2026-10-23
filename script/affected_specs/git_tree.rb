# frozen_string_literal: true

require "open3"

module AffectedSpecs
  # The repo as Picker sees it: the working tree (rev nil), or a commit's
  # tree when a range ends at one; +base+ is what added_lines compares it
  # with. Plain git calls, no Bundler.
  class GitTree
    def initialize(root, rev = nil, base: nil)
      @root = root
      @rev = rev
      @base = base
    end

    # The suite's specs and the shipped bundles' own (lib/samagotchi/bundles/<name>/spec/).
    def spec_files
      files("spec").select { |path| path.end_with?("_spec.rb") && !path.start_with?("spec/fixtures/") } +
        files("lib/samagotchi/bundles").select { |path| path.match?(%r{\Alib/samagotchi/bundles/[^/]+/spec/.*_spec\.rb\z}) }
    end

    def node_tests = files("spec/web/public").select { |path| path.match?(%r{\Aspec/web/public/[^/]+\.test\.js\z}) }

    def read(path)
      if @rev
        out, status = Open3.capture2("git", "show", "#{@rev}:#{path}", chdir: @root, err: File::NULL)
        status.success? ? out : nil
      else
        full = File.join(@root, path)
        File.file?(full) ? File.read(full) : nil
      end
    end

    # The lines +path+ (a spec or spec support file) adds since the base, as
    # [[line number, text], …]: `git diff -U0`'s + lines, numbered from its
    # hunk headers, one diff for all the specs. An untracked file adds all
    # of its lines; with no base, nothing is added.
    def added_lines(path)
      return [] unless @base
      return numbered(read(path).to_s) if untracked.include?(path)

      added.fetch(path, [])
    end

    # { path => count } of +paths+ whose text has +text+ (a whole word when
    # +word+).
    def mentions(text, paths, word: false)
      return {} if paths.empty?

      args = ["grep", "-c", "-F", "-I"]
      args << "-w" if word
      args << "--untracked" unless @rev
      args += ["-e", text]
      args << @rev if @rev
      args += ["--", *paths]
      out, = Open3.capture2("git", *args, chdir: @root, err: File::NULL)
      out.lines.to_h do |line|
        line = line.chomp.delete_prefix("#{@rev}:") if @rev
        path, count = line.chomp.rpartition(":").values_at(0, 2)
        [path, count.to_i]
      end
    end

    private

    def numbered(text) = text.lines(chomp: true).each_with_index.map { |line, index| [index + 1, line] }

    def untracked
      @untracked ||= @rev ? [] : git("ls-files", "--others", "--exclude-standard", "--", *SPEC_DIRS).lines(chomp: true)
    end

    SPEC_DIRS = %w[spec lib/samagotchi/bundles].freeze

    # { path => [[line number, text], …] } from one diff of the spec folders.
    def added
      @added ||= begin
        diff = git("diff", "-U0", "--no-renames", "--no-color", "--no-ext-diff", @base, *@rev, "--", *SPEC_DIRS)
        parse_added(diff)
      end
    end

    def parse_added(diff)
      path = nil
      number = nil
      diff.lines(chomp: true).each_with_object({}) do |line, added|
        if line.start_with?("diff --git ")
          path = number = nil
        elsif number.nil? && line.start_with?("+++ ")
          path = line.delete_prefix("+++ ").delete_prefix("b/")
        elsif (hunk = line.match(/\A@@ -\S+ \+(\d+)/))
          number = hunk[1].to_i
        elsif number && path && line.start_with?("+")
          (added[path] ||= []) << [number, line[1..]]
          number += 1
        end
      end
    end

    def files(dir)
      @files ||= {}
      @files[dir] ||= if @rev
                        git("ls-tree", "-r", "--name-only", @rev, "--", dir).lines(chomp: true)
                      else
                        Dir.glob("#{dir}/**/*", base: @root).select { |path| File.file?(File.join(@root, path)) }
                      end
    end

    def git(*)
      out, status = Open3.capture2("git", *, chdir: @root, err: File::NULL)
      status.success? ? out : ""
    end
  end
end
