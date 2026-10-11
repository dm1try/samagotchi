# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A temp folder of its own with `git init`, for a spec that needs a git
# repo: the checkout itself may not be one (a copy without .git, an unpacked
# gem). Made on first use in an example, removed after it (spec_helper).
# Included in every example group by spec_helper.
#
#   root = Samagotchi::ProjectScope.root_for(git_repo)
module SpecGitRepo
  def git_repo
    @spec_git_repo ||= Dir.mktmpdir("spec-git-repo").tap { |dir| system("git", "init", "-q", dir, exception: true) }
  end

  def remove_git_repo
    FileUtils.rm_rf(@spec_git_repo) if @spec_git_repo
  end
end
