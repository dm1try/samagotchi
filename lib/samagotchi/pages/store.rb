# frozen_string_literal: true

require "fileutils"
require_relative "../pages"

module Samagotchi
  module Pages
    # Where pages live: the scripts (<config>/samagotchi/pages/NAME.rb), each
    # one's output (<state>/samagotchi/pages/NAME/output.json) and its lock
    # (<state>/samagotchi/pages/NAME.lock, beside the folder so a remove can
    # delete the folder while holding it). A failed run rewrites only the
    # error: the blocks of the last good run stay. Every path is built after
    # Pages.check_name!.
    module Store
      OUTPUT = "output.json"
      # How much of a failure's message is kept.
      MAX_MESSAGE = 2000

      module_function

      def output_dir(name) = File.join(Pages.state_dir, Pages.check_name!(name))
      def output_path(name) = File.join(output_dir(name), OUTPUT)
      def lock_path(name) = File.join(Pages.state_dir, "#{Pages.check_name!(name)}.lock")

      # @return [String, nil] the sha256 of NAME's script, nil when it has none
      def script_sha(name)
        path = Pages.script_path(name)
        File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil
      end

      # @return [Stored] never ran when the output file is missing or unreadable
      def read(name)
        raw = read_raw(name)
        error = raw["error"]
        error = if error.is_a?(Hash) && error["message"].is_a?(String)
                  Failure.new(message: error["message"], line: error["line"].is_a?(Integer) ? error["line"] : nil,
                              at: string(error["at"]), script_sha: string(error["script_sha"]))
                end
        ran_at = string(raw["ran_at"])
        Stored.new(name: name, title: string(raw["title"]), blocks: ran_at && raw["blocks"].is_a?(Array) ? raw["blocks"] : [],
                   ran_at: ran_at, duration_ms: raw["duration_ms"].is_a?(Numeric) ? raw["duration_ms"] : nil,
                   script_sha: string(raw["script_sha"]), error: error, current_sha: script_sha(name))
      end

      # Every script with a valid name, by name; a file whose name breaks
      # the rule is skipped.
      # @return [Array<Stored>]
      def list
        return [] unless File.directory?(Pages.scripts_dir)

        Dir.children(Pages.scripts_dir).filter_map do |file|
          name = file.delete_suffix(".rb")
          name if file.end_with?(".rb") && Pages.valid_name?(name) && File.file?(File.join(Pages.scripts_dir, file))
        end.sort.map { |name| read(name) }
      end

      # A good run: its blocks replace the last ones and the error is cleared.
      # @raise [Refused] the output is over MAX_OUTPUT_BYTES
      # @return [Stored]
      def record_run(name, title:, blocks:, duration_ms:, script_sha:)
        stored = Stored.new(name: name, title: title, blocks: blocks, ran_at: now, duration_ms: duration_ms,
                            script_sha: script_sha, error: nil, current_sha: script_sha)
        json = JSON.generate(stored.to_json_hash)
        if json.bytesize > MAX_OUTPUT_BYTES
          raise Refused, format("the output is %<kb>.1f KB (at most %<max>d KB)", kb: json.bytesize / 1024.0,
                                                                                  max: MAX_OUTPUT_BYTES / 1024)
        end

        write(name, json)
        stored
      end

      # A failed run: the error is set; the last good run's blocks stay.
      # The one writer of a failure, for the runner (the script's) and the
      # launcher (a cut, a runner with no result) alike.
      # @return [Stored]
      def record_failure(name, message:, line:, script_sha:)
        message = message.to_s
        message = "#{message[0, MAX_MESSAGE - 1]}…" if message.size > MAX_MESSAGE
        stored = read(name).with(error: Failure.new(message: message, line: line, at: now, script_sha: script_sha))
        write(name, JSON.generate(stored.to_json_hash))
        stored
      end

      # Runs the block holding NAME's lock (flock, non-blocking).
      # @raise [Busy] another process holds it
      def locked(name)
        path = lock_path(name)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::RDWR | File::CREAT, 0o644) do |lock|
          raise Busy, name unless lock.flock(File::LOCK_EX | File::LOCK_NB)

          yield
        end
      end

      # Deletes NAME's script and output folder under its lock, then the lock.
      # @raise [Missing] no script and no output
      # @raise [Busy] it is running
      def remove(name)
        script = Pages.script_path(name)
        raise Missing, name unless File.exist?(script) || File.exist?(output_dir(name))

        locked(name) do
          FileUtils.rm_f(script)
          FileUtils.rm_rf(output_dir(name))
          FileUtils.rm_f(lock_path(name))
        end
      end

      # The output file's identity (its inode): AtomicFile renames a new file
      # in for every write, so a run that wrote changes it, even within the
      # same second. nil when there is none.
      def file_id(name)
        File.stat(output_path(name)).ino
      rescue SystemCallError
        nil
      end

      def write(name, json)
        FileUtils.mkdir_p(output_dir(name))
        AtomicFile.write(output_path(name), json)
      end

      def read_raw(name)
        raw = JSON.parse(File.read(output_path(name), encoding: Encoding::UTF_8))
        raw.is_a?(Hash) ? raw : {}
      rescue JSON::ParserError, SystemCallError, EncodingError
        {}
      end

      def string(value) = value.is_a?(String) ? value : nil

      def now = Time.now.utc.iso8601
    end
  end
end
