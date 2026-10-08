# frozen_string_literal: true

require "yaml"

module LLMContextLive
  # One task: a real merged fix replayed from its parent commit. The model
  # gets the turns (each a prompt; "{repo}" becomes the run's repo path);
  # the fix's spec changes are held back and graded afterwards.
  #
  # - fix: the fix commit; the run's repo is its parent.
  # - hidden: spec files as the fix left them, copied into the run's repo
  #   at grading as <name>_p6hidden_spec.rb (default: the fix's *_spec.rb).
  # - regression: specs of the run's own repo run alongside (default: the
  #   hidden ones' paths, as the model left them).
  # - fix_files: the fix's set, for scope (default: the files it changed).
  # - overrides: a folder whose files stand in for the fix's hidden ones
  #   (hidden/<task id>/<path> next to the tasks file; nil without one):
  #   for a fix whose spec pins a detail another correct fix would differ
  #   on.
  Task = Data.define(:id, :fix, :size, :turns, :hidden, :regression, :fix_files, :overrides) do
    def initialize(overrides: nil, **fields) = super

    # A hidden spec's text from the overrides folder, nil when it has none.
    def override(path)
      file = overrides && File.join(overrides, path)
      file && File.file?(file) ? File.read(file) : nil
    end

    def turn_text(index, repo:) = turns.fetch(index).gsub("{repo}", repo)

    # Where a hidden spec goes in the run's repo.
    def self.hidden_path(path) = path.sub(/_spec\.rb\z/, "_p6hidden_spec.rb")
  end

  # An arm: the LLM context strategy a run starts under (chi send --new
  # --llm-context).
  Arm = Data.define(:name, :strategy) do
    def flag = strategy.empty? ? "none" : strategy.join(",")
  end

  ARMS = {
    "none" => Arm.new(name: "none", strategy: []),
    "stale" => Arm.new(name: "stale", strategy: %w[stale]),
    "stale_forget" => Arm.new(name: "stale_forget", strategy: %w[stale forget])
  }.freeze

  # The tasks YAML (kept outside the repo, plan D4):
  #
  #   source_repo: /path/to/samagotchi
  #   tasks:
  #     T0:
  #       fix: bb1b50b3
  #       size: XS
  #       turns: ["find the cause … in {repo}", "implement it …"]
  #       hidden: [spec/tools/memory_spec.rb]     # optional
  #       regression: [spec/tools/memory_spec.rb] # optional
  #       fix_files: [lib/samagotchi/tools/memory.rb] # optional
  #
  # hidden/<task id>/spec/… next to it overrides a hidden spec (Task#override).
  class TaskFile
    attr_reader :source_repo, :tasks

    # @param git [#call] (argv) => stdout, for the defaults read from the
    #   fix commit
    def self.load(path, git:)
      data = YAML.safe_load_file(path)
      raise ArgumentError, "#{path}: no tasks" unless data.is_a?(Hash) && data["tasks"].is_a?(Hash)

      new(source_repo: File.expand_path(data.fetch("source_repo")), raw: data["tasks"], git: git,
          hidden_dir: File.join(File.dirname(File.expand_path(path)), "hidden"))
    end

    def initialize(source_repo:, raw:, git:, hidden_dir: nil)
      @source_repo = source_repo
      @hidden_dir = hidden_dir
      @tasks = raw.map { |id, fields| task(id.to_s, fields, git) }
    end

    # The tasks named in +ids+ (all for nil), in the file's order.
    def select(ids)
      return tasks if ids.nil?

      unknown = ids - tasks.map(&:id)
      raise ArgumentError, "unknown task(s): #{unknown.join(", ")}" unless unknown.empty?

      tasks.select { |task| ids.include?(task.id) }
    end

    private

    def task(id, fields, git)
      fix = fields.fetch("fix").to_s
      turns = Array(fields.fetch("turns")).map(&:to_s)
      raise ArgumentError, "#{id}: no turns" if turns.empty?

      changed = fields["fix_files"] || git.call(["-C", source_repo, "show", "--name-only", "--format=", fix]).split("\n").reject(&:empty?)
      hidden = Array(fields["hidden"] || changed.grep(/_spec\.rb\z/))
      Task.new(id: id, fix: fix, size: fields["size"].to_s, turns: turns, hidden: hidden,
               regression: Array(fields["regression"] || hidden), fix_files: Array(changed),
               overrides: @hidden_dir && File.directory?(File.join(@hidden_dir, id)) ? File.join(@hidden_dir, id) : nil)
    end
  end
end
