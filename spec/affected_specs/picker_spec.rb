# frozen_string_literal: true

require_relative "../../script/affected_specs/picker"

# script/affected-specs' mapping, on an in-memory tree: changed paths in,
# ranked spec picks, node tests and hints out.
RSpec.describe AffectedSpecs::Picker do
  # Answers what Picker asks of a GitTree from a { path => text } hash.
  FakeTree = Struct.new(:files) do
    def spec_files = files.keys.select { |path| path.end_with?("_spec.rb") }
    def node_tests = files.keys.select { |path| path.end_with?(".test.js") }
    def read(path) = files[path]

    def mentions(text, paths, word: false)
      pattern = word ? /(?<![\w:])#{Regexp.escape(text)}(?!\w)/ : Regexp.new(Regexp.escape(text))
      paths.to_h { |path| [path, files.fetch(path, "").scan(pattern).size] }.select { |_, count| count.positive? }
    end
  end

  let(:files) do
    {
      "lib/samagotchi/terminal_ui/attached_loop.rb" => "module Samagotchi\n  class TerminalUI\n    class AttachedLoop\n    end\n  end\nend\n",
      "spec/terminal_ui/attached_loop_spec.rb" => "",
      "spec/attached_loop_resume_spec.rb" => "",
      "spec/web_attached_loop_spec.rb" => "",
      "spec/other_spec.rb" => "AttachedLoop.new; AttachedLoop.new",
      "spec/another_spec.rb" => "AttachedLoop",
      "spec/events_drift_spec.rb" => "",
      "spec/docs_configuration_spec.rb" => "",
      "spec/bare_mention_spec.rb" => "CLI",
      "spec/support/fake_executables.rb" => "",
      "spec/uses_fakes_spec.rb" => 'require_relative "support/fake_executables"',
      "spec/web/public/activity.test.js" => "",
      "spec/web/public/tally.test.js" => 'import { x } from "../../../lib/samagotchi/web/public/activity.js";',
      "spec/samagotchi/plugin/loop_guard_bundle_spec.rb" => ""
    }
  end

  def pick(*changed) = described_class.new(changed: changed, tree: FakeTree.new(files)).pick
  def paths(picks) = picks.map(&:path)

  it "ranks the changed spec, the named spec, the rules, the other name matches, then the specs naming the class" do
    result = pick("spec/another_spec.rb", "lib/samagotchi/terminal_ui/attached_loop.rb")

    expect(paths(result.ruby)).to eq(%w[
      spec/another_spec.rb
      spec/terminal_ui/attached_loop_spec.rb
      spec/events_drift_spec.rb
      spec/attached_loop_resume_spec.rb
      spec/web_attached_loop_spec.rb
      spec/other_spec.rb
    ])
    expect(result.ruby.first.reason).to eq("changed")
    expect(result.ruby[2].reason).to start_with("rule: ")
    expect(result.ruby.last.reason).to eq("names AttachedLoop (lib/samagotchi/terminal_ui/attached_loop.rb)")
  end

  it "ranks the name matches beside the changed file first, a same-named spec in another folder last" do
    files.merge!("lib/samagotchi/plugin/context.rb" => "", "spec/guardrails/context_spec.rb" => "", "spec/web/context_spec.rb" => "",
                 "spec/samagotchi/plugin/attached_context_spec.rb" => "", "spec/context_note_spec.rb" => "",
                 "spec/plugin_context_x_spec.rb" => "")

    expect(paths(pick("lib/samagotchi/plugin/context.rb").ruby)).to eq(%w[
      spec/plugin_context_x_spec.rb
      spec/samagotchi/plugin/attached_context_spec.rb
      spec/context_note_spec.rb
      spec/guardrails/context_spec.rb
      spec/web/context_spec.rb
    ])
  end

  it "ranks a spec named after several of the changed files first, counting only the matches beside each file" do
    files.merge!("lib/samagotchi/engine.rb" => "", "lib/samagotchi/toolkit.rb" => "", "lib/samagotchi/plugin/context.rb" => "",
                 "spec/engine_aaa_spec.rb" => "", "spec/engine_context_note_spec.rb" => "", "spec/engine_toolkit_spec.rb" => "")
    result = pick("lib/samagotchi/engine.rb", "lib/samagotchi/toolkit.rb", "lib/samagotchi/plugin/context.rb")

    expect(paths(result.ruby)).to eq(%w[spec/engine_toolkit_spec.rb spec/engine_aaa_spec.rb spec/engine_context_note_spec.rb])
    expect(result.ruby.first.reason).to eq("name matches lib/samagotchi/engine.rb (and lib/samagotchi/toolkit.rb)")
    expect(result.unmatched).to eq([])
  end

  it "picks a docs-reading spec for its doc, and nothing else for a doc" do
    expect(paths(pick("docs/configuration.md").ruby)).to eq(%w[spec/docs_configuration_spec.rb])
  end

  it "greps a short class name with its parent" do
    files["lib/samagotchi/report/cli.rb"] = "module Report\n  class CLI\n  end\nend\n"
    files["spec/report_main_spec.rb"] = "Report::CLI"

    expect(paths(pick("lib/samagotchi/report/cli.rb").ruby)).to eq(%w[spec/report_main_spec.rb])
  end

  it "gives a hub a hint instead of its specs" do
    (1..(AffectedSpecs::HUB_SPECS + 1)).each { |i| files["spec/hub#{i}_spec.rb"] = "AttachedLoop" }
    result = pick("lib/samagotchi/terminal_ui/attached_loop.rb")

    expect(paths(result.ruby)).not_to include("spec/other_spec.rb")
    expect(result.hints).to eq(["hub: AttachedLoop (lib/samagotchi/terminal_ui/attached_loop.rb) is named in 43 spec files; the full run covers it"])
  end

  it "maps a web file to its node test and the tests importing it, with the e2e hint" do
    result = pick("lib/samagotchi/web/public/activity.js")

    expect(result.ruby).to eq([])
    expect(paths(result.node)).to eq(%w[spec/web/public/activity.test.js spec/web/public/tally.test.js])
    expect(result.hints).to eq([AffectedSpecs::WEB_HINT])
  end

  it "picks the specs using a changed support file, and a bundle's specs by its name" do
    expect(paths(pick("spec/support/fake_executables.rb").ruby)).to eq(%w[spec/uses_fakes_spec.rb])
    expect(paths(pick("lib/samagotchi/bundles/loop-guard/plugin.rb").ruby)).to eq(%w[spec/samagotchi/plugin/loop_guard_bundle_spec.rb])
  end

  it "picks nothing for a change no spec matches, and names the unmatched code file" do
    result = pick("README.md", "lib/samagotchi/lonely.rb")

    expect([result.ruby, result.node, result.hints]).to eq([[], [], []])
    expect(result.unmatched).to eq(["lib/samagotchi/lonely.rb"])
  end

  it "skips a deleted spec" do
    expect(pick("spec/gone_spec.rb").ruby).to eq([])
  end
end
