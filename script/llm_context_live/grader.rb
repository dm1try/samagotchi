# frozen_string_literal: true

require "fileutils"
require "json"

module LLMContextLive
  # Grades a run's working tree (nothing needs committing, plan (d)): the
  # task's hidden specs (the fix's spec files, copied in as
  # *_p6hidden_spec.rb, or the task's override of one) and its regression specs (the run's own, as the
  # model left them), in one rspec run. Pass: rspec exits 0 with at least
  # one example. The hidden copies are removed afterwards, so a grade can
  # run again.
  class Grader
    TIMEOUT = 900
    Grade = Data.define(:pass, :examples, :failures, :hidden_failures, :status, :failed) do
      def self.from_h(hash) = new(**hash.transform_keys(&:to_sym))
    end

    def initialize(shell:)
      @shell = shell
    end

    # @param ref [String] the commit the hidden specs are read at (the fix)
    # @return [Grade]
    def grade(task, workspace, source_repo:, ref: task.fix)
      hidden = copy_hidden(task, workspace.repo, source_repo, ref)
      out = File.join(workspace.dir, "grade.json")
      FileUtils.rm_f(out)
      specs = (hidden + task.regression.select { |path| File.exist?(File.join(workspace.repo, path)) }).uniq
      ran = @shell.run(["bundle", "exec", "rspec", "--format", "json", "--out", out, *specs],
                       env: workspace.env, chdir: workspace.repo, timeout: TIMEOUT, stdin: "")
      result(ran, out, hidden)
    ensure
      hidden&.each { |path| FileUtils.rm_f(File.join(workspace.repo, path)) }
    end

    private

    def copy_hidden(task, repo, source_repo, ref)
      task.hidden.map do |path|
        text = task.override(path) || begin
          ran = @shell.run(["git", "-C", source_repo, "show", "#{ref}:#{path}"])
          raise Error, "#{task.id}: no #{path} at #{ref}" unless ran.ok?

          ran.out
        end
        target = Task.hidden_path(path)
        FileUtils.mkdir_p(File.dirname(File.join(repo, target)))
        File.write(File.join(repo, target), text)
        target
      end
    end

    def result(ran, out, hidden)
      data = File.exist?(out) ? JSON.parse(File.read(out)) : {}
      summary = data["summary"] || {}
      failed = Array(data["examples"]).reject { |example| %w[passed pending].include?(example["status"]) }
      examples = summary["example_count"].to_i
      Grade.new(pass: ran.ok? && examples.positive?, examples: examples, failures: summary["failure_count"].to_i,
                hidden_failures: failed.count { |example| hidden.any? { |path| example["file_path"].to_s.end_with?(path) } },
                status: ran.status, failed: failed.first(10).map { |example| example["full_description"].to_s[0, 200] })
    rescue JSON::ParserError
      Grade.new(pass: false, examples: 0, failures: 0, hidden_failures: 0, status: ran.status, failed: ["rspec wrote no JSON"])
    end
  end
end
