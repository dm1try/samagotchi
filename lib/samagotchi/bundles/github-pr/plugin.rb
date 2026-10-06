# frozen_string_literal: true

require "json"
require "open3"

# github-pr: a session on a branch with an open GitHub PR gets the PR
# attached as context (docs/context.md) when its worker starts: a quiet
# init task asks git for the branch and gh for its PR, and attaches it
# through this bundle's provider (manifest context_providers, which also
# serves `chi context add <PR URL>` and the web's "+ URL"). Nothing for a
# scratch session or a delegate child (D12), and nothing, quietly, without
# gh, its login, a repo or an open PR.
class Plugin
  # gh and git each get this long (a network hang must not keep a thread).
  COMMAND_SECONDS = 20

  def register(chi)
    chi.init("Looking for this branch's pull request", quiet: true) { |ctx| attach_branch_pr(ctx) }
  end

  # @return [String] what it did (the init task's summary)
  def attach_branch_pr(ctx)
    return "skipped: a scratch session" if ctx.scratch?
    return "skipped: a delegate child" if ctx.delegate?
    return "no session yet" unless ctx.session_id

    branch = run(ctx, "git", "branch", "--show-current").to_s.strip
    return "not on a branch" if branch.empty?

    json = run(ctx, "gh", "pr", "view", "--json", "number,url,state") or return "no pull request for #{branch}"
    pr = JSON.parse(json)
    return "pull request ##{pr["number"]} isn't open" unless pr["state"] == "OPEN"

    name = "pr-#{pr["number"]}"
    return "#{name} is attached already" if ctx.context.list.any? { |source| source[:name] == name || source[:hint] == pr["url"] }

    ctx.context.attach(url: pr["url"], name: name, why: "branch #{branch} has open PR ##{pr["number"]}")
    "attached #{name}"
  rescue StandardError => e
    ctx.log.info(:pr_not_attached, error: e.class.name, msg: e.message.to_s[0, 200])
    "no pull request attached"
  end

  private

  # stdout of a command that succeeded within COMMAND_SECONDS, else nil.
  def run(ctx, *command)
    Open3.popen2(*command, chdir: ctx.cwd, err: File::NULL, pgroup: true) do |stdin, stdout, wait|
      stdin.close
      reader = Thread.new { stdout.read }
      unless wait.join(COMMAND_SECONDS)
        begin
          Process.kill("KILL", -wait.pid)
        rescue SystemCallError
          nil
        end
        return nil
      end
      output = reader.value
      wait.value.success? ? output : nil
    end
  rescue SystemCallError
    nil
  end
end
