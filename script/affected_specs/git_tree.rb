# frozen_string_literal: true

require "open3"

module AffectedSpecs
  # The repo as Picker sees it: the working tree (rev nil), or a commit's
  # tree when a range ends at one. Plain git calls, no Bundler.
  class GitTree
    def initialize(root, rev = nil)
      @root = root
      @rev = rev
    end

    def spec_files = files("spec").select { |path| path.end_with?("_spec.rb") && !path.start_with?("spec/fixtures/") }
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
