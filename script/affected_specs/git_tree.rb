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

    # The new-side line numbers a change to the code file +path+ (lib/,
    # script/, bin/chi) touches since the base: each hunk's lines, a pure
    # deletion's line before it (so the def around it still counts). One
    # `git diff -U0` for all the code files; an untracked file touches all
    # of its lines; with no base, none.
    def changed_lines(path)
      return [] unless @base
      return (1..read(path).to_s.lines.size).to_a if untracked_code.include?(path)

      changed.fetch(path, [])
    end

    # { word => { path => count } } of +paths+ whose text has each of
    # +words+ as a whole word: one `git grep -o` for them all. A Perl regex
    # (an alternation, ~3x faster than as many -F -w patterns); a git built
    # without PCRE gets the -F -w patterns.
    def mentions_each(words, paths)
      return {} if words.empty? || paths.empty?

      alternation = words.map { |word| Regexp.escape(word) }.join("|")
      out = grep_o(["-P", "-e", "(?<!\\w)(?:#{alternation})(?!\\w)"], paths) ||
            grep_o(["-w", "-F", *words.flat_map { |word| ["-e", word] }], paths)
      out.to_s.lines(chomp: true).each_with_object({}) do |line, found|
        line = line.delete_prefix("#{@rev}:") if @rev
        path, word = line.split(":", 2)
        next unless word

        counts = (found[word] ||= Hash.new(0))
        counts[path] += 1
      end
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

    # `git grep -o` output for +pattern_args+ over +paths+ (empty when
    # nothing matches); nil when git refuses them (no PCRE).
    def grep_o(pattern_args, paths)
      args = ["grep", "-o", "-I"]
      args << "--untracked" unless @rev
      args += pattern_args
      args << @rev if @rev
      args += ["--", *paths]
      out, status = Open3.capture2("git", *args, chdir: @root, err: File::NULL)
      out if status.success? || status.exitstatus == 1
    end

    def numbered(text) = text.lines(chomp: true).each_with_index.map { |line, index| [index + 1, line] }

    def untracked
      @untracked ||= @rev ? [] : git("ls-files", "--others", "--exclude-standard", "--", *SPEC_DIRS).lines(chomp: true)
    end

    SPEC_DIRS = %w[spec lib/samagotchi/bundles].freeze
    CODE_DIRS = %w[lib script bin/chi].freeze

    def untracked_code
      @untracked_code ||= @rev ? [] : git("ls-files", "--others", "--exclude-standard", "--", *CODE_DIRS).lines(chomp: true)
    end

    # { path => [line number, …] } from one diff of the code folders.
    def changed
      @changed ||= begin
        diff = git("diff", "-U0", "--no-renames", "--no-color", "--no-ext-diff", @base, *@rev, "--", *CODE_DIRS)
        parse_changed(diff)
      end
    end

    # A hunk header's new side is +start[,count]+ (no count: 1); a count of
    # 0 is a pure deletion after line +start+.
    def parse_changed(diff)
      path = nil
      diff.lines(chomp: true).each_with_object({}) do |line, changed|
        if line.start_with?("diff --git ")
          path = nil
        elsif path.nil? && line.start_with?("+++ ")
          path = line.delete_prefix("+++ ").delete_prefix("b/")
        elsif path && (hunk = line.match(/\A@@ -\S+ \+(\d+)(?:,(\d+))? @@/))
          start = hunk[1].to_i
          count = hunk[2] ? hunk[2].to_i : 1
          lines = count.zero? ? [[start, 1].max] : (start...(start + count)).to_a
          (changed[path] ||= []).concat(lines)
        end
      end
    end

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
