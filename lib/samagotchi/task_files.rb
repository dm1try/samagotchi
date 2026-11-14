# frozen_string_literal: true

require "json"
require_relative "tools/task_record"

module Samagotchi
  # Where a background task's files are: tmp/tasks/<id>/ in the worker's
  # cwd, its task.json (a Tools::TaskRecord), output.log and exit_code. The
  # layout only, and the one cheap read a UI row makes (command_of); no
  # process code: Tools::TaskRuntime starts, refreshes and stops the tasks.
  #
  # TASKS_DIR and EXIT_CODE_FILENAME are on the bundle boundary's stable
  # list (lib/samagotchi/testing/boundary.rb): the slow-commands bundle
  # reads tmp/tasks/*/task.json and the exit_code beside it.
  module TaskFiles
    TASKS_DIR = File.join("tmp", "tasks")
    METADATA_FILENAME = "task.json"
    OUTPUT_FILENAME = "output.log"
    EXIT_CODE_FILENAME = "exit_code"
    # A task id as task_create makes them: no path parts.
    TASK_ID = /\A[A-Za-z0-9_-]+\z/

    module_function

    def metadata_path(task_id)
      File.join(task_dir_for(task_id), METADATA_FILENAME)
    end

    def task_dir_for(task_id)
      File.join(TASKS_DIR, task_id.to_s)
    end

    # The command of the task +task_id+ under +root+ (a session's working
    # directory) as its record has it, for a UI row's title; nil for no
    # such task or an unreadable record. Reads the record only (no
    # refresh), so it is cheap and never fails.
    # @return [String, nil]
    def command_of(task_id, root: Dir.pwd)
      id = task_id.to_s.strip
      return nil unless id.match?(TASK_ID)

      path = File.join(root || Dir.pwd, TASKS_DIR, id, METADATA_FILENAME)
      return nil unless File.file?(path)

      command = Tools::TaskRecord.from_file(JSON.parse(File.read(path)))&.command
      command.is_a?(String) && !command.strip.empty? ? command : nil
    rescue StandardError # degrade-ok: a row's title; an unreadable record has none (moved from TaskRuntime)
      nil
    end
  end
end
