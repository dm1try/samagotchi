# frozen_string_literal: true

require "bundler/gem_tasks"

lib_dir = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib_dir) unless $LOAD_PATH.include?(lib_dir)
require "samagotchi/version"

Gem::Specification.new do |spec|
  spec.name          = "samagotchi"
  spec.version       = Samagotchi::VERSION
  spec.summary       = "Agent harness which heavily relies on memory"
  spec.description   = "An agent harness which heavily relies on memory. Includes Engine, TerminalUI, memory system, and agentic tool execution."
  spec.authors       = ["samagotchi"]
  spec.email         = [""]
  spec.homepage      = "https://github.com/dmitrydedov/samagotchi"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  # Guard against accidental push to rubygems.org (not published yet)
  spec.authors << " [DO NOT PUSH TO RUBYGEMS]"

  # Collect files: lib/, bin/, README.md only.
  # Explicit listing avoids pulling in spec/, docs/, Gemfile, etc.
  # Use relative paths (relative to __dir__) for clean gem contents.
  spec.files = Dir.glob(File.join("lib", "**/*")) +
               Dir.glob(File.join("bin", "*")) +
               ["README.md"]
  # Exclude Ruby LSP internal files
  spec.files.reject! { |f| f.start_with?(".ruby-lsp/") }
  spec.bindir        = "bin"
  spec.executables   = ["chi"]
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "reline"
  spec.add_dependency "nokogiri"
  spec.add_dependency "ruby_llm"

  # Development dependencies
  spec.add_development_dependency "rspec", "~> 3"
  spec.add_development_dependency "webmock"
end
