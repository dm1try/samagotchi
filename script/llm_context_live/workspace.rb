# frozen_string_literal: true

require "fileutils"
require "yaml"

module LLMContextLive
  # One run's folder under the root (runs/<id>/): the repo the model works
  # in, chi's isolated config and state (the smoke-run recipe), and the
  # environment every chi and rspec command of the run gets.
  class Workspace
    STEP_LIMIT = 150
    BUNDLES = %w[loop-guard].freeze

    attr_reader :dir

    def initialize(dir)
      @dir = File.expand_path(dir)
    end

    def repo = File.join(dir, "repo")
    def config_home = File.join(dir, "config")
    def state_home = File.join(dir, "state")
    def sessions_dir = File.join(state_home, "samagotchi", "sessions")
    def log_path = File.join(state_home, "samagotchi", "samagotchi.log")

    # chi's isolation: a test session (SAMAGOTCHI_ENV), its own state and
    # config, and no inherited SAMAGOTCHI_HOSTS_JSON (it would beat the
    # config copy's hosts).
    def env
      { "SAMAGOTCHI_ENV" => "test", "XDG_STATE_HOME" => state_home, "XDG_CONFIG_HOME" => config_home,
        "SAMAGOTCHI_HOSTS_JSON" => nil }
    end

    # The repo at +commit+ of +source_repo+ (git archive, then a fresh git
    # repo with one "base" commit, so the model's diff is against it).
    def prepare_repo(source_repo, commit, shell:)
      FileUtils.rm_rf(repo)
      FileUtils.mkdir_p(repo)
      tar = File.join(dir, "base.tar")
      check(shell.run(["git", "-C", source_repo, "archive", "--format=tar", "-o", tar, commit]), "git archive #{commit}")
      check(shell.run(["tar", "-xf", tar, "-C", repo]), "tar")
      FileUtils.rm_f(tar)
      git = ["git", "-c", "user.name=p6", "-c", "user.email=p6@localhost", "-C", repo]
      check(shell.run([*git, "init", "-q", "-b", "main"]), "git init")
      check(shell.run([*git, "add", "-A"]), "git add")
      check(shell.run([*git, "commit", "-qm", "base #{commit}"]), "git commit")
    end

    # chi's config: the model's host copied from the user's config (its
    # api_key_env names a variable, never a key), the step limit, no recap
    # (no model calls besides the turns), payoff and no stale_edits (the
    # defaults, written down).
    def write_config(model:, hosts:)
      host = model[/\A([\w.-]+):/, 1] or raise ArgumentError, "#{model}: a host-qualified model ref (host:model)"
      entry = hosts[host] or raise ArgumentError, "no host #{host} in the hosts config"
      config = { "default" => { "model" => model }, "hosts" => { host => entry },
                 "turn" => { "max_iterations" => STEP_LIMIT }, "recap" => false,
                 "llm_context" => { "apply" => "payoff", "stale_edits" => false } }
      path = File.join(config_home, "samagotchi", "config.yml")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump(config))
      FileUtils.mkdir_p(state_home)
      path
    end

    def install_bundles(chi:, shell:)
      BUNDLES.each do |name|
        check(shell.run([chi, "bundle", "install", name], env: env, chdir: dir, timeout: 120, stdin: ""), "chi bundle install #{name}")
      end
    end

    private

    def check(ran, what)
      return if ran.ok?

      raise Error, "#{what} failed (#{ran.status.inspect}): #{ran.err.strip[-500..] || ran.err.strip}"
    end
  end

  class Error < StandardError; end
end
