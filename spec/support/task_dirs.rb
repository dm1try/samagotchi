# frozen_string_literal: true

require "tmpdir"
require "samagotchi/testing/waiting"
require "samagotchi/tools/task_runtime"

# A spec that starts real background tasks (TaskRuntime.create_task, a
# task_create call, an execute handed over as a task) runs in a tasks'
# folder of its own and leaves nothing running:
#
#   around { |example| with_task_dir { example.run } }
#
# The ensure stops every task still running, then joins chi's exit-status
# recorders (TaskRuntime.quiesce!), which may still write exit_code or the
# record into the folder: removing it first fails (ENOTEMPTY) or races.
# A recorder still alive after the (scaled) deadline fails the example.
module TaskDirs
  QUIESCE_TIMEOUT = 5

  # @yield [String] the folder, also the current directory
  def with_task_dir
    Dir.mktmpdir("samagotchi-tasks") do |dir|
      Dir.chdir(dir) do
        yield dir
      ensure
        quiesce_tasks!
      end
    end
  end

  def quiesce_tasks!
    runtime = Samagotchi::Tools::TaskRuntime
    runtime.list_records.select(&:running?).each do |record|
      runtime.stop_task(record.id, by: "model")
    rescue StandardError => e
      # The others still stop, and the recorders are still joined.
      warn("with_task_dir: stopping #{record.id} failed: #{e.class}: #{e.message}")
    end
    waiting = Samagotchi::Testing::Waiting
    alive = runtime.quiesce!(timeout: waiting.scaled(QUIESCE_TIMEOUT))
    # An error on its way out of the block (an inline use's failed
    # expectation) stays the one raised; in an around hook RSpec lists both.
    return if alive.empty? || $!

    raise waiting::TimedOut,
          waiting.timed_out_message("the tasks' exit-status recorders to finish (#{alive.size} still alive)", QUIESCE_TIMEOUT)
  end
end
