# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

# The built gem ships lib/, bin/chi, docs/*.md, README, LICENSE (and
# CHANGELOG.md once it exists): nothing from the dev tree, no directories.
RSpec.describe "The built gem" do
  root = File.expand_path("..", __dir__)
  # Built and listed once, in a process of its own: Ruby 3.3's zlib (3.1)
  # raises Zlib::BufError when a thread interrupt hits a deflate, and this
  # process has threads (ruby/zlib#57, fixed in zlib 3.2.3, Ruby 3.4).
  lister = <<~RUBY
    require "rubygems/package"
    spec = Gem::Specification.load("samagotchi.gemspec")
    path = Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) { Gem::Package.build(spec, true, false, ARGV[0]) }
    puts Gem::Package.new(path).contents
  RUBY

  before(:context) do
    Dir.mktmpdir("gem-contents") do |dir|
      out, err, status = Open3.capture3(RbConfig.ruby, "-e", lister, File.join(dir, "s.gem"), chdir: root)
      raise "building the gem failed: #{err}" unless status.success?

      @files = out.lines(chomp: true)
    end
  end

  let(:files) { @files }

  it "ships the code, the executable, the docs, README and LICENSE" do
    expect(files).to include("lib/samagotchi.rb", "bin/chi", "README.md", "LICENSE", "docs/configuration.md",
                             "lib/samagotchi/bundles/system/manifest.yml", "lib/samagotchi/web/public/index.html")
    expect(files).to include("CHANGELOG.md") if File.file?(File.join(root, "CHANGELOG.md"))
  end

  it "ships nothing from the dev tree" do
    leaked = files.select do |f|
      f.match?(%r{\A(spec|tmp|pkg|script|node_modules|\.claude)/}) || f == "AGENT.md" ||
        f.split("/").any? { |part| part.start_with?(".") }
    end
    expect(leaked).to eq([])
  end

  it "ships only files, only under lib/, bin/, docs/ or the top-level docs" do
    expect(files.reject { |f| File.file?(File.join(root, f)) }).to eq([])
    expect(files.reject { |f| f.match?(%r{\A(lib|bin|docs)/}) || %w[README.md LICENSE CHANGELOG.md].include?(f) }).to eq([])
  end
end
