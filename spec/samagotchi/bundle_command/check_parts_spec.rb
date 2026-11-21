# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "stringio"
require "tmpdir"
require "samagotchi/bundle_command"
require "samagotchi/bundle_command/check"
require "samagotchi/memory_bundle/shas"
require "samagotchi/testing"

# `chi bundle check` on a plugin in several files (plugin: parts:): parts are
# listed files, a stray top-level .rb is unlisted, and the source checks
# (floor, api, fail-closed) read every file of the plugin.
RSpec.describe Samagotchi::BundleCommand::Check, "plugin parts" do
  let(:fixture) { File.expand_path("../../fixtures/plugin_parts_bundle", __dir__) }
  let(:tmp) { File.realpath(Dir.mktmpdir("check-parts-")) }
  let(:dir) { File.join(tmp, "plugin-parts") }
  let(:out) { StringIO.new }

  around { |example| with_config_home(File.join(tmp, "config")) { example.run } }

  before { FileUtils.cp_r(fixture, dir) }

  after { FileUtils.rm_rf(tmp) }

  def edit(rel) = File.write(File.join(dir, rel), yield(File.read(File.join(dir, rel))))
  def refresh! = File.write(File.join(dir, "manifest.yml"), Samagotchi::MemoryBundle::Shas.refresh(dir).first)

  def findings(level)
    Samagotchi::BundleCommand.new(["check", dir], stdout: out, stderr: StringIO.new).run
    out.string.lines.map(&:chomp).select { |line| line.start_with?("#{level} ") }
  end

  it "installs and loads the fixture cleanly in the sandbox" do
    expect(findings(:error)).to eq([])
    expect(findings(:warn)).to eq([])
    expect(out.string).to include("info registered plugin.rb: command /parts")
  end

  it "missing-file: a listed part that isn't there" do
    FileUtils.rm(File.join(dir, "shout.rb"))
    expect(findings(:error)).to eq(["error missing-file manifest.yml:10: lists shout.rb, which isn't in the bundle " \
                                    "(fix: add the file or drop the entry)"])
  end

  it "unlisted: a top-level .rb the plugin's parts don't list" do
    File.write(File.join(dir, "extra.rb"), "# x\n")
    expect(findings(:warn)).to eq(["warn unlisted extra.rb: manifest.yml's plugin: parts: doesn't list it, so an install " \
                                   "leaves it out (fix: list it under plugin: parts:, then chi bundle check --fix)"])
  end

  it "sha: a stale part line" do
    edit("shout.rb") { |text| "#{text}# edited\n" }
    expect(findings(:error)).to include("error sha manifest.yml:10: a stale sha256 for shout.rb (fix: chi bundle check --fix)")
  end

  it "requires-chi-floor and fail-closed name the part a call is in, the newest call across the files, and its line" do
    edit("shout.rb") do |text|
      text.sub("    def say(text) = super.upcase\n", "    def say(text) = super.upcase\n\n    def cost(ctx) = ctx.cost.total\n")
    end
    refresh!
    edit("manifest.yml") { |text| text.sub('requires_chi: ">= 0.1.28"', 'requires_chi: ">= 0.80.0"') }
    expect(findings(:warn)).to eq(['warn requires-chi-floor manifest.yml:11: requires_chi ">= 0.80.0" admits chi 0.80.0, ' \
                                   'but shout.rb uses ctx.cost, which needs chi 0.83.0 (fix: requires_chi: ">= 0.83.0")'])

    out.truncate(0)
    out.rewind
    edit("helpers.rb") do |text|
      text.sub("  module Helpers\n", "  module Helpers\n    def guard(chi) = chi.on(:before_tool_call, on_error: :fail_closed) { nil }\n")
    end
    refresh!
    warnings = findings(:warn)
    expect(warnings.first).to start_with('warn requires-chi-floor manifest.yml:11: requires_chi ">= 0.80.0" admits chi 0.80.0, ' \
                                         "but helpers.rb uses chi.on(on_error:), which needs chi 0.157.0")
    expect(warnings.last).to start_with("warn fail-closed helpers.rb:7: a fail-closed chi.on hook")
  end
end
