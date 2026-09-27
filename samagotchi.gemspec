# frozen_string_literal: true

lib_dir = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)
require "samagotchi/version"

Gem::Specification.new do |spec|
  spec.name          = "samagotchi"
  spec.version       = Samagotchi::VERSION
  spec.authors       = ["Dmitry Dedov"]
  spec.email         = ["me@dmitry.it"]
  spec.summary       = "chi: a local-first coding agent with memory, sessions and a web UI"
  spec.description   = <<~DESC.tr("\n", " ").strip
    chi is an agent harness for local and OpenAI-compatible models (llama.cpp,
    mlx, oMLX, hosted APIs). It runs sessions in a terminal REPL or in background
    workers you can attach to from the terminal and a web UI, keeps memories in
    plain files shared as bundles, and extends through hooks, guardrails,
    plugins and MCP servers.
  DESC
  spec.homepage      = "https://github.com/dm1try/samagotchi"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata = {
    "source_code_uri" => "https://github.com/dm1try/samagotchi",
    "changelog_uri" => "https://github.com/dm1try/samagotchi/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/dm1try/samagotchi/issues",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }

  # lib/, bin/, docs/*.md, README, LICENSE and CHANGELOG: tracked files only
  # (never directories or untracked scratch under lib/). The agent reads docs/
  # from its installed source dir (see bundles/system/self_map.md).
  patterns = %w[lib/**/* bin/* docs/**/*.md README.md LICENSE CHANGELOG.md]
  tracked = Dir.chdir(__dir__) do
    `git ls-files -z -- #{patterns.map { |p| "':(glob)#{p}'" }.join(" ")} 2>/dev/null`.split("\x0")
  end
  tracked = Dir.chdir(__dir__) { patterns.flat_map { |p| Dir.glob(p) } } if tracked.empty? # no git: an unpacked source
  spec.files = Dir.chdir(__dir__) { tracked.select { |f| File.file?(f) }.sort.uniq }
  spec.bindir        = "bin"
  spec.executables   = ["chi"]
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "reline", "~> 0.6.3" # the TUI seam uses private LineEditor methods
  spec.add_dependency "json", ">= 2.9" # Ruby 3.3's json 2.7 pretty-prints {} as "{\n}" in the tool schemas of the prompt
  spec.add_dependency "nokogiri"
  spec.add_dependency "rack", ">= 2.0"
  spec.add_dependency "rackup"
  spec.add_dependency "webrick"
end
