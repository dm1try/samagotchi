# frozen_string_literal: true

require "json"
require "optparse"
require "yaml"
require_relative "runner"
require_relative "report"

module LLMContextLive
  # script/llm_context_live.rb (docs/internals/llm-context-live.md):
  #
  #   validate TASKS ROOT   each task's hidden specs fail at the fix's parent
  #                         and pass at the fix (no model)
  #   run TASKS ROOT        the matrix (resumable)
  #   grade TASKS ROOT RUN… grade runs again (their working trees)
  #   collect TASKS ROOT RUN… collect runs' numbers again
  #   report ROOT           the scoring table and the gate
  class CLI
    CHI = File.expand_path("../../bin/chi", __dir__)
    HOSTS_CONFIG = File.expand_path("~/.config/samagotchi/config.yml")

    def initialize(argv, out: $stdout, err: $stderr, shell: Shell.new, chi: CHI)
      @argv = argv.dup
      @out = out
      @err = err
      @shell = shell
      @chi = chi
    end

    def run
      options = { arms: ARMS.keys, samples: 1, budget: 64_000, cap: 8.0, jobs: 1, hosts_config: HOSTS_CONFIG, json: false }
      parser = parser(options)
      command, *rest = parser.parse(@argv)
      case command
      when "validate" then validate(*rest, options)
      when "run" then run_matrix(*rest, options)
      when "grade", "collect" then again(command, *rest, options)
      when "report" then report(*rest, options)
      else
        @err.puts parser
        2
      end
    rescue OptionParser::ParseError, ArgumentError, Error => e
      @err.puts "llm_context_live: #{e.message}"
      2
    end

    private

    def parser(options)
      OptionParser.new do |o|
        o.banner = "usage: script/llm_context_live.rb (validate|run|grade|collect|report) TASKS ROOT [RUN…] [options]"
        o.on("--tasks LIST", "task ids, comma-separated (default all)") { |list| options[:tasks] = list.split(",") }
        o.on("--arms LIST", "arms: #{ARMS.keys.join(", ")} (default all)") { |list| options[:arms] = list.split(",") }
        o.on("--samples N", Integer, "samples per task × arm (default 1)") { |n| options[:samples] = n }
        o.on("--model REF", "a host-qualified chi model ref (host:model)") { |ref| options[:model] = ref }
        o.on("--budget N", "llm_context budget in tokens, or off (default 64000)") do |value|
          options[:budget] = %w[off 0].include?(value) ? nil : Integer(value)
        end
        o.on("--cap USD", Float, "stop starting runs once the ledger reaches USD (default 8)") { |usd| options[:cap] = usd }
        o.on("--jobs N", Integer, "runs at once (default 1)") { |n| options[:jobs] = n }
        o.on("--limit N", Integer, "start at most N new runs") { |n| options[:limit] = n }
        o.on("--hosts-config PATH", "where the model's host is copied from (default #{HOSTS_CONFIG})") do |path|
          options[:hosts_config] = path
        end
        o.on("--json", "report: JSON") { options[:json] = true }
      end
    end

    def task_file(path) = TaskFile.load(path, git: ->(argv) { @shell.run(["git", *argv]).out })

    def run_matrix(tasks_path, root, options)
      raise ArgumentError, "run needs --model" unless options[:model]

      file = task_file(tasks_path)
      arms = options[:arms].map { |name| ARMS.fetch(name) { raise ArgumentError, "unknown arm #{name}" } }
      hosts = YAML.safe_load_file(options[:hosts_config]).fetch("hosts")
      runner = Runner.new(root: root, task_file: file, chi: @chi, shell: @shell, log: @err, model: options[:model],
                          budget: options[:budget], cap: options[:cap], jobs: options[:jobs], limit: options[:limit],
                          hosts: hosts)
      runner.run(Runner.plan(file.select(options[:tasks]), arms, options[:samples]))
    end

    # Per task: the hidden specs at the fix's parent (expected red) and at
    # the fix (expected green).
    def validate(tasks_path, root, options)
      file = task_file(tasks_path)
      grader = Grader.new(shell: @shell)
      bad = 0
      file.select(options[:tasks]).each do |task|
        grades = { parent: "#{task.fix}^", fix: task.fix }.to_h do |label, commit|
          workspace = Workspace.new(File.join(File.expand_path(root), "validate", "#{task.id}-#{label}"))
          workspace.prepare_repo(file.source_repo, commit, shell: @shell)
          [label, grader.grade(task, workspace, source_repo: file.source_repo)]
        end
        good = !grades[:parent].pass && grades[:fix].pass
        bad += 1 unless good
        @out.puts "#{task.id} #{task.fix}: parent #{line(grades[:parent])}; fix #{line(grades[:fix])} #{good ? "OK" : "BAD"}"
      end
      bad.zero? ? 0 : 1
    end

    def line(grade) = "#{grade.pass ? "pass" : "fail"} (#{grade.examples} ex, #{grade.failures} fail, #{grade.hidden_failures} hidden)"

    def again(command, tasks_path, root, *ids, _options)
      file = task_file(tasks_path)
      ids.each do |id|
        path = File.join(File.expand_path(root), "results", "#{id}.json")
        result = JSON.parse(File.read(path))
        task = file.select([result["task"]]).first
        workspace = Workspace.new(File.join(File.expand_path(root), "runs", id))
        if command == "grade"
          result["grade"] = Grader.new(shell: @shell).grade(task, workspace, source_repo: file.source_repo).to_h
        else
          wall = result.dig("metrics", "wall_seconds")
          result["metrics"] = Collector.new(shell: @shell).collect(task, workspace, result["session_id"]).merge(wall_seconds: wall)
        end
        File.write(path, JSON.pretty_generate(result))
        @out.puts "#{id}: #{command} done"
      end
      0
    end

    def report(root, options)
      report = Report.load(File.expand_path(root))
      @out.puts(options[:json] ? JSON.pretty_generate(report.to_h) : report.text)
      0
    end
  end
end
