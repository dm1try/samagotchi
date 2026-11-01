# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Samagotchi
  module SystemOne
    # Runs on disk: <state>/system_one/runs/<judgment>/YYYY-MM-DD.jsonl (UTC,
    # 0600), one append under flock per line, read by copying the lines out
    # and parsing outside the lock; each judgment's questions once per digest
    # pair in versions.jsonl beside them. Nothing is rewritten but for a
    # session's purge.
    class RunsStore
      DIR = File.join("system_one", "runs")
      # A judgment's name: safe as a folder name, dot-separated words.
      NAME = /\A[a-z0-9][a-z0-9_-]*(?:\.[a-z0-9][a-z0-9_-]*)*\z/
      VERSIONS = "versions.jsonl"
      DAY_FILE = /\A\d{4}-\d{2}-\d{2}\.jsonl\z/
      FILE_MODE = 0o600
      DIR_MODE = 0o700
      # The longest line: a longer state is saved cut, marked "truncated".
      MAX_LINE_BYTES = 16 * 1024

      attr_reader :dir

      # @param root [String] the state dir the sessions folder sits in
      def initialize(root)
        @dir = File.join(root, DIR)
      end

      # @param line [Hash] with its "at"
      # @return [Boolean] true: raises what the filesystem raises
      def append(judgment, line)
        write(File.join(judgment_dir(judgment), "#{day_of(line)}.jsonl"), fit(line))
        true
      end

      # +line+ ({digests…, "questions"}) unless the file has its digest pair.
      # @return [Boolean] whether it was new
      def version(judgment, line)
        path = File.join(judgment_dir(judgment), VERSIONS)
        with_file(path) do |file|
          known = file.each_line.any? do |text|
            data = parse(text)
            data && data["instructions_digest"] == line["instructions_digest"] && data["criteria_digest"] == line["criteria_digest"]
          end
          next false if known

          file.seek(0, IO::SEEK_END)
          file.write("#{JSON.generate(line)}\n")
          true
        end
      end

      # The judgments with a folder, sorted; a folder that isn't one is left
      # alone, and in no one's way.
      # @return [Array<String>]
      def names
        return [] unless Dir.exist?(@dir)

        Dir.children(@dir).select { |name| name.match?(NAME) && File.directory?(File.join(@dir, name)) }.sort
      end

      # Every parseable line, oldest day first.
      # @param since [String, nil] the first day (YYYY-MM-DD) wanted
      # @return [Array<Hash>]
      def lines(judgment, since: nil)
        day_files(judgment).flat_map do |path|
          next [] if since && File.basename(path, ".jsonl") < since

          read(path).each_line.filter_map { |text| parse(text) }
        end
      end

      # The questions saved, one line per digest pair.
      # @return [Array<Hash>]
      def versions(judgment)
        path = File.join(judgment_dir(judgment), VERSIONS)
        File.exist?(path) ? read(path).each_line.filter_map { |text| parse(text) } : []
      end

      # @return [Integer] the judgment's bytes on disk
      def size(judgment)
        Dir.children(judgment_dir(judgment)).sum { |name| File.size(File.join(judgment_dir(judgment), name)) }
      rescue SystemCallError
        0
      end

      # Day files past +days+ (0: none), then the oldest until the total is
      # under +max_bytes+, today's stay. A judgment with no day file left
      # loses its versions and folder.
      # @return [Integer] the day files deleted
      def sweep(days:, max_bytes:, now: Time.now.utc)
        return 0 unless Dir.exist?(@dir)

        today = now.utc.strftime("%F")
        cutoff = (now.utc - (days * 86_400)).strftime("%F") if days.positive?
        files = names.flat_map { |name| day_files(name) }.sort_by { |path| File.basename(path) }
        expired, kept = files.partition { |path| cutoff && File.basename(path, ".jsonl") < cutoff }
        total = names.sum { |name| size(name) } - expired.sum { |path| File.size(path) }
        over = kept.take_while do |path|
          next false if total <= max_bytes || File.basename(path, ".jsonl") >= today

          total -= File.size(path)
          true
        end
        (expired + over).each { |path| FileUtils.rm_f(path) }
        names.each { |name| remove_if_empty(name) }
        expired.size + over.size
      end

      # One session's runs and the later lines on them, rewritten out of the
      # day files under the lock.
      # @return [Integer] the runs purged
      def purge_session(session_id)
        needle = session_id.to_s
        return 0 if needle.empty?

        names.sum do |name|
          files = day_files(name).select { |path| read(path).include?(needle) }
          ids = files.flat_map { |path| session_run_ids(path, needle) }
          next 0 if ids.empty?

          known = ids.to_h { |id| [id, true] }
          day_files(name).each { |path| rewrite_without(path, known) }
          remove_if_empty(name)
          ids.size
        end
      end

      private

      def judgment_dir(judgment)
        name = judgment.to_s
        raise ArgumentError, "not a judgment's name: #{name.inspect}" unless name.match?(NAME)

        File.join(@dir, name)
      end

      def day_files(judgment)
        dir = judgment_dir(judgment)
        return [] unless Dir.exist?(dir)

        Dir.children(dir).grep(DAY_FILE).sort.map { |name| File.join(dir, name) }
      end

      def day_of(line) = line.fetch("at")[0, 10]

      # The line as written: past the cap its state is cut, as a string, as
      # little as fits (escaping makes a byte cost more than one in the line:
      # the most that fits is searched for) and marked; a line that doesn't
      # fit with no state at all keeps its facts only.
      def fit(line)
        text = JSON.generate(line)
        return text if text.bytesize <= MAX_LINE_BYTES

        line = line.merge("truncated" => true)
        state = line["state"].is_a?(String) ? line["state"] : JSON.generate(line["state"])
        cut = ->(bytes) { JSON.generate(line.merge("state" => state.byteslice(0, bytes).scrub(""))) }
        return JSON.generate(line.except("state", "answers", "failure_text")) if cut.call(0).bytesize > MAX_LINE_BYTES

        bytes = (0..[state.bytesize, MAX_LINE_BYTES].min).bsearch { |size| cut.call(size + 1).bytesize > MAX_LINE_BYTES }
        cut.call(bytes || [state.bytesize, MAX_LINE_BYTES].min)
      end

      def write(path, text)
        FileUtils.mkdir_p(File.dirname(path), mode: DIR_MODE)
        File.open(path, File::WRONLY | File::APPEND | File::CREAT, FILE_MODE) do |file|
          file.flock(File::LOCK_EX)
          file.write("#{text}\n")
        end
      end

      def with_file(path)
        FileUtils.mkdir_p(File.dirname(path), mode: DIR_MODE)
        File.open(path, File::RDWR | File::CREAT, FILE_MODE) do |file|
          file.flock(File::LOCK_EX)
          yield file
        end
      end

      # The file's text, copied out under a shared lock.
      def read(path)
        File.open(path, File::RDONLY) do |file|
          file.flock(File::LOCK_SH)
          file.read
        end
      rescue SystemCallError
        ""
      end

      def parse(text)
        data = JSON.parse(text)
        data.is_a?(Hash) ? data : nil
      rescue JSON::ParserError
        nil
      end

      def session_run_ids(path, session_id)
        read(path).each_line.filter_map do |text|
          next unless text.include?(session_id)

          data = parse(text)
          data["id"] if data && data["kind"] == "run" && data["session_id"] == session_id
        end
      end

      def rewrite_without(path, ids)
        with_file(path) do |file|
          kept = file.each_line.reject do |text|
            data = parse(text)
            data && (ids[data["id"]] || ids[data["run_id"]])
          end
          file.rewind
          file.write(kept.join)
          file.flush
          file.truncate(file.pos)
        end
        FileUtils.rm_f(path) if File.empty?(path)
      end

      def remove_if_empty(name)
        return unless day_files(name).empty?

        FileUtils.rm_rf(judgment_dir(name))
      end
    end
  end
end
