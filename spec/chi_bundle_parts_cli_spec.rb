# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "yaml"
require "samagotchi/bundle_command"
require "samagotchi/live_versions"
require "samagotchi/memory_bundle/shas"

# What `chi bundle install/upgrade/status/diff` say of a plugin in several
# files (plugin: parts:): the Plugin: line counts the parts, status names a
# part that won't load, diff takes a part, and a changed part asks for the
# restart a changed plugin file does.
RSpec.describe "chi bundle with plugin parts" do
  let(:tmpdir) { File.realpath(Dir.mktmpdir("chi-bundle-parts-")) }
  let(:fixture) { File.expand_path("fixtures/plugin_parts_bundle", __dir__) }
  let(:plugin_dir) { File.join(Samagotchi::MemoryPaths.system_dir, ".bundles", "plugin-parts", "plugin") }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  before { FileUtils.mkdir_p(Samagotchi::MemoryPaths.system_dir) }

  after { FileUtils.rm_rf(tmpdir) }

  def source
    @source ||= File.join(tmpdir, "src").tap { |dir| FileUtils.cp_r(fixture, dir) }
  end

  def chi(*args)
    out = StringIO.new
    err = StringIO.new
    code = Samagotchi::BundleCommand.new(args, stdin: StringIO.new(""), stdout: out, stderr: err).run
    [out.string, err.string, code]
  end

  it "counts the parts in the install's Plugin: line" do
    out, _, code = chi("install", source)
    expect(code).to eq(0)
    expect(out).to include("Installed: helpers.rb, shout.rb, plugin.rb\n")
    expect(out).to include("Plugin: plugin.rb + 2 parts (loads at the next chi start)\n")
  end

  it "names a part that won't load under the status's Plugin: line, and counts it once in the listing" do
    chi("install", source)
    expect(chi("status", "plugin-parts").first).to include("  Plugin: plugin.rb [ok]\n")
    File.write(File.join(plugin_dir, "shout.rb"), "# mine\n")
    File.write(File.join(plugin_dir, "helpers.rb"), "# mine\n")
    out = chi("status", "plugin-parts").first
    expect(out).to include("  Plugin: plugin.rb [ok]\n    " \
                           "part helpers.rb [modified] (edited after install: not loaded; reinstall the bundle)\n    " \
                           "part shout.rb [modified] (edited after install: not loaded; reinstall the bundle)\n")
    expect(chi("status").first).to match(/plugin-parts v1\.0\.0 .* plugin=plugin\.rb issues=1$/)
  end

  it "diffs a part by its name or plugin/<name>, and every part in the whole-bundle diff" do
    chi("install", source)
    File.write(File.join(plugin_dir, "shout.rb"), "# mine\n")
    %w[shout.rb plugin/shout.rb].each do |arg|
      out = chi("diff", "plugin-parts", arg).first
      expect(out).to start_with("=== plugin/shout.rb ===\n--- base (provenance) ---\n#{File.read(File.join(fixture, "shout.rb"))}")
      expect(out).to include("# mine\n")
      expect(out).to include("--- metadata: sha256=#{Samagotchi::InstalledBundles::FileDigest.sha256(File.join(fixture, "shout.rb"))}")
    end
    headings = chi("diff", "plugin-parts").first.lines.grep(/\A=== /).map(&:chomp)
    expect(headings).to eq(["=== plugin/helpers.rb ===", "=== plugin/shout.rb ===", "=== plugin/plugin.rb ==="])
  end

  it "asks for a restart when only a part changed" do
    allow(Samagotchi::LiveVersions).to receive(:workers).and_return(
      [Samagotchi::LiveVersions::Worker.new(session_id: "aaaa1111", version: Samagotchi::VERSION, restart: true)]
    )
    chi("install", source)
    File.write(File.join(source, "shout.rb"), "#{File.read(File.join(source, "shout.rb"))}# v2\n")
    manifest = YAML.load_file(File.join(source, "manifest.yml")).merge("version" => "1.1.0")
    File.write(File.join(source, "manifest.yml"), YAML.dump(manifest))
    File.write(File.join(source, "manifest.yml"), Samagotchi::MemoryBundle::Shas.refresh(source).first)
    out = chi("upgrade", source).first
    expect(out).to include("Updated: shout.rb\n")
    expect(out).to end_with("1 session runs the old code: chi sessions restart aaaa1111\n")
  end
end
