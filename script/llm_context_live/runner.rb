# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "tasks"
require_relative "shell"
require_relative "workspace"
require_relative "driver"
require_relative "grader"
require_relative "collector"
require_relative "ledger"

module LLMContextLive
  # The matrix: every task × arm × sample, sample-major (one of each before
  # the second of any), each run in its own workspace under
  # <root>/runs/<run id>, its result in <root>/results/<run id>.json.
  # Resumable: a run with a result is skipped, one without is started over.
  # Before each run the ledger's stop file and the cost cap are checked.
  class Runner
    Planned = Data.define(:id, :task, :arm, :sample)

    # @param settings [Hash] model:, budget: (Integer or nil for off), cap:,
    #   jobs:, limit: (new runs to start, nil for all)
    def initialize(root:, task_file:, chi:, shell: Shell.new, log: $stderr, **settings)
      @root = File.expand_path(root)
      @task_file = task_file
      @chi = chi
      @shell = shell
      @log = log
      @settings = settings
      @ledger = Ledger.new(@root)
      @mutex = Mutex.new
    end

    def self.plan(tasks, arms, samples)
      (1..samples).flat_map do |sample|
        tasks.flat_map do |task|
          arms.map { |arm| Planned.new(id: "#{task.id}-#{arm.name}-s#{sample}", task: task, arm: arm, sample: sample) }
        end
      end
    end

    def result_path(id) = File.join(@root, "results", "#{id}.json")

    # @return [Integer] the exit status: 0 done (or the --limit reached),
    #   1 stopped (cap, payment)
    def run(planned)
      todo = planned.reject { |run| File.exist?(result_path(run.id)) }
      todo = todo.first(@settings[:limit]) if @settings[:limit]
      @log.puts "llm_context_live: #{planned.size - todo.size} of #{planned.size} done; starting #{todo.size}"
      queue = Queue.new
      todo.each { |run| queue << run }
      queue.close
      @stopped = nil
      workers = Array.new([@settings.fetch(:jobs, 1), 1].max) do
        Thread.new do
          while (run = queue.pop)
            break if blocked?

            one(run)
          end
        end
      end
      workers.each(&:join)
      @log.puts "llm_context_live: stopped: #{@stopped}; spent $#{format("%.2f", @ledger.total)}" if @stopped
      @stopped ? 1 : 0
    end

    private

    def blocked?
      @mutex.synchronize do
        @stopped ||= @ledger.blocked(@settings[:cap])
        !@stopped.nil?
      end
    end

    def one(run)
      workspace = Workspace.new(File.join(@root, "runs", run.id))
      @log.puts "llm_context_live: #{run.id} starting"
      prepare(run, workspace)
      outcome = Driver.new(chi: @chi, shell: @shell, log: @log).run(run.task, workspace, model: @settings.fetch(:model), flags: flags(run))
      metrics = Collector.new(shell: @shell).collect(run.task, workspace, outcome.session_id)
      save_diff(workspace)
      grade = Grader.new(shell: @shell).grade(run.task, workspace, source_repo: @task_file.source_repo)
      @ledger.add(run.id, metrics[:cost])
      @ledger.stop!("a payment error in #{run.id}") if outcome.payment
      write(run, outcome, metrics, grade)
      @log.puts "llm_context_live: #{run.id} #{grade.pass ? "pass" : "FAIL"}, #{metrics[:steps]} steps, " \
                "$#{format("%.3f", metrics[:cost].to_f)}, #{outcome.wall_seconds}s#{" PAYMENT" if outcome.payment}"
    rescue Error, SystemCallError => e
      @log.puts "llm_context_live: #{run.id} not run: #{e.message}"
    end

    def prepare(run, workspace)
      FileUtils.rm_rf(workspace.dir)
      FileUtils.mkdir_p(workspace.dir)
      workspace.prepare_repo(@task_file.source_repo, "#{run.task.fix}^", shell: @shell)
      workspace.write_config(model: @settings.fetch(:model), hosts: @settings.fetch(:hosts))
      workspace.install_bundles(chi: @chi, shell: @shell)
    end

    def flags(run)
      budget = @settings[:budget]
      ["--llm-context", run.arm.flag, "--llm-context-budget", budget ? budget.to_s : "off"]
    end

    # The model's work against the base commit, for reviewing a fail
    # (untracked files too: the Collector marked them intent-to-add).
    def save_diff(workspace)
      base = @shell.run(["git", "-C", workspace.repo, "rev-list", "--max-parents=0", "HEAD"]).out.split.first
      return unless base

      File.write(File.join(workspace.dir, "diff.patch"), @shell.run(["git", "-C", workspace.repo, "diff", base]).out)
    end

    def write(run, outcome, metrics, grade)
      path = result_path(run.id)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(
        run: run.id, task: run.task.id, arm: run.arm.name, sample: run.sample, model: @settings[:model],
        budget: @settings[:budget], session_id: outcome.session_id, outcome: outcome.to_h,
        metrics: metrics.merge(wall_seconds: outcome.wall_seconds), grade: grade.to_h
      ))
    end
  end
end
