# frozen_string_literal: true

require "open3"
require "optparse"
require_relative "git_tree"
require_relative "picker"

module AffectedSpecs
  # script/affected-specs [RANGE] [--why] [--all] [--cap N] [--run]
  #
  # The Ruby specs go to stdout, one per line, so
  # `bundle exec rspec $(script/affected-specs)` runs them; the node tests,
  # hints and the "more" line go to stderr.
  class CLI
    DEFAULT_CAP = 10

    def initialize(argv, out: $stdout, err: $stderr, dir: Dir.pwd)
      @argv = argv.dup
      @out = out
      @err = err
      @dir = dir
    end

    # @return [Integer] 0, or 2 for a usage or git error
    def run
      options = parse
      return 2 unless options

      root = git("rev-parse", "--show-toplevel")&.chomp
      return fail_with("not in a git repository") || 2 unless root

      @root = root

      changed, tree = changes(root, options[:range])
      return 2 unless changed

      report(Picker.new(changed: changed, tree: tree).pick, options)
    end

    private

    def parse
      options = { cap: DEFAULT_CAP }
      parser = OptionParser.new do |o|
        o.banner = <<~TEXT
          usage: script/affected-specs [RANGE] [options]

          Lists the spec files to run for a change, best first: changed specs, specs named
          after a changed file, the rules for specs that read docs or source as text, then
          specs that name the changed file's class. Ruby specs on stdout (for
          `bundle exec rspec $(script/affected-specs)`); node tests and hints on stderr.

          RANGE: A..B, A...B (from their merge-base), or a base REV (compared with the
          working tree). Default: the merge-base with main (or origin/main), plus
          uncommitted and untracked files.
        TEXT
        o.on("--why", "Print the reason for each pick") { options[:why] = true }
        o.on("--all", "No cap") { options[:cap] = nil }
        o.on("--cap N", Integer, "Show at most N Ruby specs (default #{DEFAULT_CAP})") do |n|
          raise OptionParser::InvalidArgument, n.to_s if n.negative?

          options[:cap] = n
        end
        o.on("--run", "Run the Ruby picks with bundle exec rspec") { options[:run] = true }
      end
      rest = parser.parse(@argv)
      return usage(parser) if rest.size > 1

      options.merge(range: rest.first)
    rescue OptionParser::ParseError => e
      @err.puts "affected-specs: #{e.message}"
      usage(parser)
    end

    def usage(parser)
      @err.puts parser.help
      nil
    end

    # [changed paths, tree] for the range; nil after an error message.
    def changes(root, range)
      if range&.include?("..")
        from, to = range.split(/\.{2,3}/, 2)
        to = "HEAD" if to.to_s.empty?
        from = git("merge-base", from, to, chdir: root)&.chomp || from if range.include?("...")
        diff = git("diff", "--name-only", "--no-renames", from, to, chdir: root)
        return fail_with("bad range #{range}") unless diff

        return [diff.lines(chomp: true), GitTree.new(root, to)]
      end

      base = range || main_base(root)
      diff = git("diff", "--name-only", "--no-renames", base, chdir: root)
      return fail_with("bad revision #{base}") unless diff

      untracked = git("ls-files", "--others", "--exclude-standard", chdir: root).to_s
      [(diff.lines(chomp: true) + untracked.lines(chomp: true)).uniq, GitTree.new(root)]
    end

    # The merge-base with main, else origin/main (a single-branch clone, CI);
    # else HEAD, said on stderr: only uncommitted changes count then.
    def main_base(root)
      %w[main origin/main].each do |ref|
        base = git("merge-base", ref, "HEAD", chdir: root)&.chomp
        return base if base
      end
      @err.puts "affected-specs: no main or origin/main; only uncommitted changes"
      "HEAD"
    end

    def report(result, options)
      # A range ending at another commit can pick specs this checkout lacks.
      missing, present = result.ruby.partition { |pick| !File.file?(File.join(@root, pick.path)) }
      @err.puts "affected-specs: not in this checkout, skipped: #{missing.map(&:path).join(" ")}" unless missing.empty?
      result = result.with(ruby: present)
      ruby = options[:cap] ? result.ruby.first(options[:cap]) : result.ruby
      node = options[:cap] ? result.node.first(options[:cap]) : result.node
      ruby.each { |pick| @out.puts(options[:why] ? "#{pick.path}  # #{pick.reason}" : pick.path) }
      more = result.ruby.size - ruby.size
      @err.puts "affected-specs: #{more} more (--all lists them)" if more.positive?
      unless node.empty?
        if options[:why]
          node.each { |pick| @err.puts "npm: #{pick.path}  # #{pick.reason}" }
        else
          @err.puts "npm test targets: node --test #{node.map(&:path).join(" ")}"
        end
      end
      result.hints.each { |hint| @err.puts "affected-specs: #{hint}" }
      result.unmatched.each { |path| @err.puts "affected-specs: no spec found for #{path}" } if options[:why]
      return 0 unless options[:run] && !ruby.empty?

      @out.flush
      system("bundle", "exec", "rspec", *ruby.map(&:path), chdir: @root) ? 0 : 1
    end

    def git(*, chdir: @dir)
      out, status = Open3.capture2("git", *, chdir: chdir, err: File::NULL)
      status.success? ? out : nil
    end

    def fail_with(message)
      @err.puts "affected-specs: #{message}"
      nil
    end
  end
end
