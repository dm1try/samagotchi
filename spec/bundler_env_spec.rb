# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "samagotchi/bundler_env"

RSpec.describe Samagotchi::BundlerEnv do
  # All `bundle exec` adds, asked of the Bundler this suite's Ruby has: a name a
  # newer Bundler adds fails here, not in a project's `ruby -e` under chi.
  it "names every variable `bundle exec` sets for a child ruby" do
    clean = ENV.keys.grep(/\A(?:BUNDLE|RUBYOPT\z|RUBYLIB\z|GEM_)/).to_h { |key| [key, nil] }
    Dir.mktmpdir("bundler-env") do |dir|
      File.write(File.join(dir, "Gemfile"), "")
      script = 'print ENV.keys.grep(/\ABUNDLE/).reject { |key| key.start_with?("BUNDLER_ORIG_") }.join(" ")'
      out, err, status = Open3.capture3(clean, RbConfig.ruby, "-S", "bundle", "exec", "ruby", "-e", script, chdir: dir)
      expect(status).to be_success, err
      expect(out.split).to include("BUNDLE_GEMFILE", "BUNDLER_SETUP")
      expect(out.split - described_class::VARS).to eq([])
    end
  end

  it "holds them all under its prefix" do
    expect(described_class::VARS).to all(start_with(described_class::PREFIX))
  end
end
