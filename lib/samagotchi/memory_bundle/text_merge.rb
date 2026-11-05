# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "../git_env"

module Samagotchi
  module MemoryBundle
    # The text merge of an upgrade: three texts in, the merged text or why
    # there is none out. Writes nothing but its temp copies; Merger::Upgrade
    # asks and Merger.write_merged writes.
    #
    # It runs `git merge-file`. git isn't a chi runtime dependency, so no git,
    # or the macOS stand-in that would pop an install dialog, is a :failed
    # result: the caller keeps the file. Any doubt about what git answered reads
    # the same way, and markers never leave this module.
    #
    # A hunk under a Changelog heading unions, ours then theirs' new entries
    # (#union?), when nothing in or around it could make it more than a list of
    # entries both sides only added to: see Scan. Any other hunk is a real conflict.
    module TextMerge
      MARKER_SIZE = 20
      OURS = "yours"
      THEIRS = "bundle"
      OPEN = "#{"<" * MARKER_SIZE} #{OURS}".freeze
      SEPARATOR = ("=" * MARKER_SIZE).freeze
      BASE = "base"
      BASE_MARK = "#{"|" * MARKER_SIZE} #{BASE}".freeze
      CLOSE = "#{">" * MARKER_SIZE} #{THEIRS}".freeze
      # git merge-file's exit status: the conflicts, capped; 255 is its error.
      MAX_COUNTED = 127

      # Seconds git may take. It runs under SystemBundle's lock at every chi start.
      TIMEOUT = 10

      # Where macOS keeps the stand-in, and what says whether it is one.
      APPLE_STUB = "/usr/bin/git"
      XCODE_SELECT = "/usr/bin/xcode-select"

      NO_GIT = "git not found"
      STUB_GIT = "#{APPLE_STUB} needs the command line tools: xcode-select --install".freeze
      NOT_TEXT = "a side isn't text"
      UNREADABLE = "git's answer couldn't be read"
      NO_BASE = "no recorded base"
      RACED = "the file changed during the merge"
      TIMED_OUT = "git took too long"

      # heading: the title of the last heading before it, nil when a rule or
      # underline came after that one. ours, base, theirs: its lines on each
      # side. union: it passed Scan's rule.
      Hunk = Data.define(:heading, :ours, :base, :theirs, :union) do
        def union? = union
      end

      # status: :clean (text is the merged text, hunks the unioned ones),
      # :conflict (hunks has at least one that doesn't union; no text) or
      # :failed (why says why there is no answer).
      Result = Data.define(:status, :text, :hunks, :why) do
        def clean? = status == :clean
      end

      module_function

      # @param base [String] the file as last installed
      # @param ours [String] the file on disk
      # @param theirs [String] the bundle's new file
      # @return [Result]
      def merge(base:, ours:, theirs:)
        return failed(NOT_TEXT) if [base, ours, theirs].any? { |text| text.b.include?("\0") }

        git = find_git
        return failed(NO_GIT) unless git
        return failed(STUB_GIT) if apple_stub?(git)

        output, code = run_git(git, base, ours, theirs)
        return failed(TIMED_OUT) if code == :timeout
        return failed(UNREADABLE) if code.nil? || code > MAX_COUNTED

        scan = Scan.new(output)
        return failed(UNREADABLE) unless scan.read? && [scan.hunks.size, MAX_COUNTED].min == code && from_inputs?(scan.lines, base, ours, theirs)

        if scan.clean?
          Result.new(status: :clean, text: scan.text, hunks: scan.hunks, why: nil)
        else
          Result.new(status: :conflict, text: nil, hunks: scan.hunks, why: nil)
        end
      rescue SystemCallError => e
        failed("git couldn't run: #{e.message}")
      end

      def failed(why) = Result.new(status: :failed, text: nil, hunks: [], why: why)

      # What +theirs+ changed against +base+ and +ours+ hasn't got, section by
      # section: what a file that kept its own text has missed. A conflict's hunks
      # can't say that: the whole file stays, so a change git would have merged is
      # missed too, and the one hunk may be a Changelog line beside a whole new
      # section. A section the user already brought over by hand isn't missed, nor
      # one the bundle took out and the user did too.
      # A heading (as written, "## Steps") names its section, the deepest one; a
      # Changelog comes last, being the least of it.
      # @return [Array(Array<String>, Boolean)] the headings; whether text under
      #   no heading changed
      def changed_sections(base, theirs, ours)
        before, after, held = [base, theirs, ours].map do |text|
          # Where a section falls leaves blank lines of its own at the end.
          Scan.new(text).sections.map { |heading, lines| [heading, lines.join.strip] }
        end
        headings = (after - before - held).map(&:first)
        gone = (before - after).map(&:first) - after.map(&:first)
        names = (headings + (gone & held.map(&:first))).uniq
        unnamed = names.include?(nil)
        changelog, named = names.compact.partition { |name| name.sub(/\A#+[ \t]*/, "").match?(Scan::CHANGELOG) }
        [named + changelog, unnamed]
      end

      # Whether git's answer is made of the inputs' lines: anything else (an
      # empty answer to non-empty inputs too) must never replace a memory.
      def from_inputs?(lines, *inputs)
        known = inputs.flat_map { |text| text.b.each_line.map(&:chomp) }.to_h { |line| [line, true] }
        return known.empty? if lines.empty?

        lines.all? { |line| known.key?(line.chomp) }
      end

      # The first executable git on PATH, nil without one.
      def find_git(path: ENV.fetch("PATH", ""))
        path.split(File::PATH_SEPARATOR).reject(&:empty?).map { |dir| File.join(dir, "git") }
            .find { |file| File.file?(file) && File.executable?(file) }
      end

      # Whether +git+ is macOS's stand-in with no developer tools behind it:
      # running it pops a dialog. Unknown counts as yes.
      def apple_stub?(git)
        return false unless darwin? && same_file?(git, APPLE_STUB)

        dir, status = Open3.capture2e(XCODE_SELECT, "-p")
        !(status.success? && File.directory?(dir.strip))
      rescue SystemCallError
        true
      end

      def darwin? = RUBY_PLATFORM.include?("darwin")

      def same_file?(one, other)
        File.identical?(one, other)
      rescue SystemCallError
        false
      end

      # Temp copies in a temp cwd, with nothing inherited that could point git
      # at a repository or a config: this runs inside other tools' hooks, whose
      # GIT_DIR once defeated the temp cwd.
      # @return [Array(String, Integer)] stdout, the exit status (nil: killed;
      #   :timeout: it passed TIMEOUT and was stopped)
      def run_git(git, base, ours, theirs)
        Dir.mktmpdir("chi-merge-") do |dir|
          { OURS => ours, BASE => base, THEIRS => theirs }.each { |name, text| File.binwrite(File.join(dir, name), text) }
          capture_git(git_env(dir), [git, "merge-file", "-p", "--diff3", "--marker-size=#{MARKER_SIZE}",
                                     "-L", OURS, "-L", BASE, "-L", THEIRS, OURS, BASE, THEIRS], dir)
        end
      end

      # In a process group of its own: /usr/bin/git may be a launcher with the
      # real git as its child.
      def capture_git(env, command, dir)
        Open3.popen2(env, *command, chdir: dir, err: File::NULL, pgroup: true) do |stdin, stdout, wait|
          stdin.close
          stdout.binmode
          reader = Thread.new { stdout.read }
          unless wait.join(TIMEOUT)
            stop_group(wait.pid)
            reader.kill
            next ["", :timeout]
          end
          [reader.value, wait.value.exitstatus]
        end
      end

      def stop_group(pid)
        Process.kill("KILL", -pid)
      rescue SystemCallError
        nil
      end

      def git_env(dir)
        GitEnv::UNSET.merge("GIT_CONFIG_PARAMETERS" => nil, "GIT_CONFIG_COUNT" => nil,
                            "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_SYSTEM" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1",
                            "GIT_CEILING_DIRECTORIES" => File.dirname(File.realpath(dir)))
      end

      # git's output, read a line at a time. Takes the markers out, keeps track
      # of the last heading outside any hunk, code fence and HTML comment, and
      # decides each hunk (D3a of the kept-edits plan). The rule is strict
      # because the naive one merges real rules silently: a fenced "## Changelog"
      # template would swallow what follows it, one hunk can span a Changelog
      # line and a real section, and a paragraph after the entries is no entry.
      # A hunk unions only when
      #   - the last heading before it is titled exactly Changelog (or Change
      #     log), at level 1 or 2, with no rule or underline after that heading
      #     and nothing but list entries between it and the hunk;
      #   - no fence or comment is open; and
      #   - base, ours and theirs each hold only list entries, and both sides
      #     still hold every entry of the base: both only added. An edited or
      #     dropped entry is a decision, and so is a base heading both dropped.
      # An entry is a list item and the lines indented deeper right under it,
      # nested items too, none of which, indentation aside, is a heading, a rule
      # or a fence; a blank line ends it. The union is ours, then the entries of
      # theirs that ours doesn't have, compared whole.
      # Marker lines that don't pair up (a user's line equal to one) mean the
      # output can't be read at all.
      class Scan
        HEADING = /\A {0,3}(\#{1,6})(?:[ \t]|\z)/
        RULE = /\A {0,3}(?:=+|-+|\*{3,}|_{3,}|([-*_])(?:[ \t]*\1){2,})[ \t]*\z/
        FENCE = /\A {0,3}(`{3,}|~{3,})/
        LIKE_HEADING = /\A {0,3}#/
        CHANGELOG = /\Achange ?log\z/i
        ITEM = /\A {0,3}(?:[-*+]|\d{1,9}[.)])[ \t]+\S/
        ITEM_MORE = /\A(?: {2,}|\t)\S/
        COMMENT_OPEN = "<!--"
        COMMENT_CLOSE = "-->"
        CHANGELOG_LEVEL = 2

        attr_reader :hunks, :lines

        # [heading as written (nil before the first), its lines], in order.
        attr_reader :sections

        def initialize(output)
          @sections = [[nil, []]]
          @hunks = []
          @pieces = []
          @lines = []
          @heading = nil
          @changelog = false
          @in_item = false
          @fence = nil
          @comment = false
          @read = read_lines(output.b.each_line)
        end

        def read? = @read

        def clean? = @hunks.all?(&:union?)

        def text = @pieces.join

        private

        # @return [Boolean] the markers paired up
        def read_lines(lines)
          state = :text
          ours = base = theirs = nil
          lines.each do |line|
            bare = line.chomp
            case state
            when :text
              return false if [BASE_MARK, CLOSE].include?(bare)

              if bare == OPEN
                ours = []
                state = :ours
              else
                add_text(line, bare)
              end
            when :ours
              return false if [OPEN, SEPARATOR, CLOSE].include?(bare)

              if bare == BASE_MARK
                base = []
                state = :base
              else
                ours << line
              end
            when :base
              return false if [OPEN, BASE_MARK, CLOSE].include?(bare)

              if bare == SEPARATOR
                theirs = []
                state = :theirs
              else
                base << line
              end
            when :theirs
              return false if [OPEN, BASE_MARK, SEPARATOR].include?(bare)

              if bare == CLOSE
                add_hunk(ours, base, theirs)
                state = :text
              else
                theirs << line
              end
            end
          end
          state == :text
        end

        def add_text(line, bare)
          @pieces << line
          @lines << line
          classify_text(bare)
          @sections.last.last << line
        end

        def classify_text(bare)
          return follow_fence(bare) if @fence || bare.match?(FENCE)
          return follow_comment(bare) if @comment || bare.include?(COMMENT_OPEN)

          if bare.match?(HEADING) then add_heading(bare)
          elsif bare.match?(RULE) then @heading = nil
          else follow_list(bare)
          end
        end

        def add_heading(bare)
          # Reports and the record take these: the scan is binary, and they need text.
          @heading = text_of(bare.sub(/\A {0,3}\#{1,6}[ \t]*/, "").sub(/[ \t#:]*\z/, ""))
          @changelog = bare[HEADING, 1].size <= CHANGELOG_LEVEL && @heading.match?(CHANGELOG)
          @in_item = false
          @sections << [text_of(bare.strip.sub(/[ \t#:]*\z/, "")), []]
        end

        # Whether the section so far is still nothing but list entries.
        def follow_list(bare)
          return @in_item = false if bare.strip.empty?

          @in_item = bare.match?(ITEM) || (@in_item && more_of_entry?(bare))
          @changelog = false unless @in_item
        end

        # An open fence closes on a line of its own character, at least as
        # long, with nothing after it.
        def follow_fence(bare)
          @changelog = false
          fence = bare[FENCE, 1]
          return @fence = fence unless @fence
          return unless fence && fence[0] == @fence[0] && fence.size >= @fence.size

          @fence = nil if bare.strip == fence
        end

        def follow_comment(bare)
          @changelog = false
          after = @comment ? bare : bare[(bare.index(COMMENT_OPEN) + COMMENT_OPEN.size)..]
          @comment = !after.include?(COMMENT_CLOSE)
        end

        def add_hunk(ours, base, theirs)
          @lines.concat(ours, base, theirs)
          union = union_of(ours, base, theirs)
          @hunks << Hunk.new(heading: @heading, ours: ours, base: base, theirs: theirs, union: !union.nil?)
          return unless union

          @pieces.concat(union)
          @in_item = true
        end

        # The union's lines, nil when this hunk isn't one.
        def union_of(ours, base, theirs)
          return nil if @fence || @comment || !@changelog || !@heading.to_s.match?(CHANGELOG)

          ours_entries = entries(ours)
          base_entries = entries(base)
          theirs_entries = entries(theirs)
          return nil unless ours_entries && base_entries && theirs_entries
          return nil unless (base_entries - ours_entries).empty? && (base_entries - theirs_entries).empty?

          ours + (theirs_entries - ours_entries).flatten
        end

        # The side's list entries, each a list of lines; nil when it holds
        # anything else.
        def entries(lines)
          attached = false
          lines.each_with_object([]) do |line, found|
            bare = line.chomp
            if bare.strip.empty?
              attached = false
            elsif structural?(bare.lstrip) then return nil
            elsif attached && bare.match?(ITEM_MORE) && indent(bare) > indent(found.last.first) then found.last << line
            elsif bare.match?(ITEM)
              found << [line]
              attached = true
            else return nil
            end
          end
        end

        def more_of_entry?(bare) = bare.match?(ITEM_MORE) && !structural?(bare.lstrip)

        def indent(line) = line[/\A[ \t]*/].size

        # As UTF-8, what isn't valid replaced: a heading is for reading.
        def text_of(bytes) = bytes.dup.force_encoding(Encoding::UTF_8).scrub

        def structural?(text) = text.match?(LIKE_HEADING) || text.match?(RULE) || text.match?(FENCE)
      end
    end
  end
end
