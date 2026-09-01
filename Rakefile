# frozen_string_literal: true

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

  desc "Clean built .gem files"
  task :clean do
    Dir.glob("*.gem").each do |f|
      File.unlink(f)
      puts "Removed #{f}"
    end
  end

  desc "Build the samagotchi gem"
  task :build do
    sh "gem build samagotchi.gemspec"
    gem_file = Dir.glob("samagotchi-*.gem").first
    if gem_file
      puts "\nBuilt: #{gem_file}"
      puts "Install with: gem install #{gem_file}"
    end
  end

  desc "Build and install the samagotchi gem locally"
  task :install => [:validate, :build] do
    gem_file = Dir.glob("samagotchi-*.gem").first
    if gem_file
      sh "gem install #{gem_file}"
    end
  end
end

# Allow `rake build` as shorthand for `rake gem:build`
Rake::Task[:build].enhance do
  Rake::Task["gem:build"].invoke
end
