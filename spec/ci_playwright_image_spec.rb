# frozen_string_literal: true

require "yaml"

# CI's e2e job runs Chromium in Playwright's image (run-server), whose
# browsers are built for one Playwright release: a client of another version
# can't drive them. The job reads the tag from the installed @playwright/test
# (package-lock.json), so a lock bump moves the image too; a tag written into
# the workflow would drift.
RSpec.describe "CI's e2e browser image" do
  root = File.expand_path("..", __dir__)

  it "takes its tag from the installed @playwright/test, not a pinned one" do
    workflow = YAML.safe_load_file(File.join(root, ".github/workflows/ci.yml"))
    script = workflow.dig("jobs", "e2e", "steps").filter_map { |step| step["run"] }.join("\n")

    expect(script).to include(%{version=$(node -p 'require("@playwright/test/package.json").version')})
    expect(script).to include("mcr.microsoft.com/playwright:v${version}-noble")
    expect(script).to include("playwright@${version}")
    expect(script).not_to match(%r{mcr\.microsoft\.com/playwright:v\d})
  end
end
