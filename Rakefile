# frozen_string_literal: true

# bundler/gem_tasks provides build/install/release; they all use pkg/.
require "bundler/gem_tasks"

namespace :gem do
  desc "Validate the gemspec"
  task :validate do
    spec = Gem::Specification.load("samagotchi.gemspec")
    result = spec.validate
    if result
      # validate returns true (ok) or array of warnings
      if result.is_a?(Array) && !result.empty?
        $stderr.puts "Gemspec validation warnings:"
        result.each { |msg| $stderr.puts "  - #{msg}" }
      end
    end
    puts "✓ Gemspec is valid"
  end

  desc "Clean built .gem files from pkg/"
  task :clean => :clobber

  desc "Build the samagotchi gem into pkg/"
  task :build => "rake:build"

  desc "Build and install the samagotchi gem locally"
  task :install => [:validate, "rake:install:local"]
end
