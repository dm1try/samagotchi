# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/working_set_locator"
require "samagotchi/prompt_part"

# WorkingSet::Locator: where a held text came from and how to fetch it
# again; #fetch's three outcomes (nil refused, gone, text) by origin.
RSpec.describe Samagotchi::WorkingSet::Locator do
  let(:dir) { Dir.mktmpdir("ws-locator") }
  let(:root) { File.join(dir, "memories").tap { |d| FileUtils.mkdir_p(d) } }

  after { FileUtils.rm_rf(dir) }

  describe "a run's stamp entry (:run)" do
    let(:entry) { File.join(root, "style.md").tap { |p| File.write(p, "be brief\n") } }

    it "reads the stamped file inside the root, says gone when it left, refuses one outside" do
      locator = described_class.of_stamp("style", { path: entry })
      expect(locator.fetch(root: root)).to have_attributes(text: "be brief\n", gone: false, diff: nil)
      expect(locator.fetch(root: root, read: ->(_path) { "stand-in" }).text).to eq("stand-in")

      File.delete(entry)
      expect(locator.fetch(root: root).gone).to be(true)

      outside = File.join(dir, "secret.md").tap { |p| File.write(p, "token\n") }
      expect(described_class.of_stamp("secret", { path: outside }).fetch(root: root)).to be_nil
      expect(described_class.of_stamp("style", "not a hash").fetch(root: root)).to be_nil
    end

    it "resolves an entry with request metadata against the root, ignoring any saved system folder" do
      File.write(entry, "be brief\n")
      elsewhere = File.join(dir, "elsewhere").tap { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(elsewhere, "style.md"), "elsewhere\n")
      stamped = { path: entry, requested_scope: nil, model_key: nil, fallback_model_key: nil, project_dir: nil,
                  system_dir: elsewhere }
      expect(described_class.of_stamp("style", stamped).fetch(root: root).text).to eq("be brief\n")
      expect(described_class.of_stamp("gone", stamped.merge(path: File.join(root, "gone.md"))).fetch(root: root).gone).to be(true)
    end
  end

  describe "a prompt part's params (:prompt)" do
    def part(kind, ref, params) = Samagotchi::PromptPart.build(kind: kind, label: ref.to_s, chars: 1, ref: ref, params: params)

    it "fetches nothing for chi's own text or an appended file" do
      appended = File.join(dir, "extra.md").tap { |p| File.write(p, "Extra.\n") }
      expect(described_class.of_part(part("appended", appended, { "path" => appended })).fetch(root: root, cwd: dir)).to be_nil
      expect(described_class.of_part(part("base", nil, nil)).fetch(root: root, cwd: dir)).to be_nil
      expect(described_class.of_part(part("indexes", "system", nil)).fetch(root: root, cwd: dir)).to be_nil
    end

    it "reads a memory with the saved folders only inside the root" do
      File.write(File.join(root, "style.md"), "be brief\n")
      params = { "requested_scope" => nil, "model_key" => nil, "fallback_model_key" => nil, "project_dir" => nil, "system_dir" => root }
      expect(described_class.of_part(part("preloads", "style", params)).fetch(root: root).text).to eq("be brief\n")
      outside = File.join(dir, "elsewhere").tap { |d| FileUtils.mkdir_p(d) }
      File.write(File.join(outside, "style.md"), "secret\n")
      expect(described_class.of_part(part("preloads", "style", params.merge("system_dir" => outside))).fetch(root: root)).to be_nil
    end

    it "refuses a note whose saved model key leads outside the root before it looks at any file" do
      File.write(File.join(root, "model_notes_tips.md"), "models: *\nNote body\n")
      outside = File.join(dir, "etc").tap { |d| FileUtils.mkdir_p(d) }
      crafted = "x/../../etc/foo"
      params = { "requested_scope" => nil, "model_key" => crafted, "fallback_model_key" => nil, "project_dir" => nil,
                 "system_dir" => root }
      locator = described_class.of_part(part("notes", "model_notes_tips", params))
      looked = []
      allow(File).to(receive(:file?).and_wrap_original { |original, path| (looked << path) && original.call(path) })

      expect(locator.fetch(root: root)).to be_nil
      File.write(File.join(outside, "foo.md"), "secret\n")
      expect(locator.fetch(root: root)).to be_nil
      expect(looked).to be_empty
      expect(described_class.of_part(part("notes", "model_notes_tips", params.merge("model_key" => "m"))).fetch(root: root).text)
        .to eq("Note body")
    end
  end

  describe "#composed (the files a prompt part's text was read from)" do
    def part(kind, ref, params, scope: nil) = Samagotchi::PromptPart.build(kind: kind, label: ref.to_s, chars: 1, ref: ref, scope: scope, params: params)

    let(:project) { File.join(root, "projects", "app_1").tap { |d| FileUtils.mkdir_p(d) } }
    let(:params) do
      { "requested_scope" => nil, "model_key" => "m", "fallback_model_key" => "fb", "project_dir" => project, "system_dir" => root }
    end

    def files(locator, cwd: nil) = locator.composed(root: root, cwd: cwd).files.map { |f| [f.path, f.role, f.key] }

    it "names a preload's base, its overlay by the model key or the fallback key, and fetches as #fetch does" do
      File.write(File.join(root, "style.md"), "be brief\n")
      locator = described_class.of_part(part("preloads", "style", params, scope: "system"))
      expect(files(locator)).to eq([[File.join(root, "style.md"), :base, nil]])
      expect(locator.composed(root: root).now).to eq(locator.fetch(root: root))

      File.write(File.join(root, "style.fb.md"), "fallback")
      expect(files(locator)).to eq([[File.join(root, "style.md"), :base, nil], [File.join(root, "style.fb.md"), :overlay, "fb"]])
      File.write(File.join(root, "style.m.md"), "for m")
      expect(files(locator).last).to eq([File.join(root, "style.m.md"), :overlay, "m"])
      expect(locator.composed(root: root).now.text).to eq("be brief\n\n\n---\n\nModel-specific guidance (m):\nfor m")
    end

    it "names a note's file and its overlay in the note's scope" do
      File.write(File.join(project, "model_notes_tips.md"), "models: *\nNote body\n")
      File.write(File.join(project, "model_notes_tips.fb.md"), "note overlay")
      locator = described_class.of_part(part("notes", "model_notes_tips", params.merge("requested_scope" => "project"), scope: "project"))
      expect(files(locator)).to eq([[File.join(project, "model_notes_tips.md"), :base, nil],
                                    [File.join(project, "model_notes_tips.fb.md"), :overlay, "fb"]])
      expect(locator.composed(root: root).now.text).to eq("Note body\n\n---\n\nModel-specific guidance (fb):\nnote overlay")
    end

    it "names an AGENTS.md's own path" do
      repo = File.join(dir, "repo").tap { |d| FileUtils.mkdir_p(File.join(d, ".git")) }
      agents = File.join(repo, "AGENTS.md").tap { |p| File.write(p, "Rules.\n") }
      locator = described_class.of_part(part("agents", "AGENTS.md", { "path" => agents }))
      expect(files(locator, cwd: repo)).to eq([[agents, :base, nil]])
      expect(locator.composed(root: root, cwd: repo).now.text).to eq("Rules.")
    end

    it "names the base a gone source was sent from: identity's system folder, a preload's built scope, a note's requested one" do
      identity = described_class.of_part(part("identity", "identity", params, scope: "system"))
      expect(identity.composed(root: root).now.gone).to be(true)
      expect(files(identity)).to eq([[File.join(root, "identity.md"), :base, nil]])
      preload = described_class.of_part(part("preloads", "style", params.merge("requested_scope" => "project"), scope: "project"))
      expect(files(preload)).to eq([[File.join(project, "style.md"), :base, nil]])
      expect(files(described_class.of_part(part("preloads", "style", params, scope: "system")))).to eq([[File.join(root, "style.md"), :base, nil]])
      note = described_class.of_part(part("notes", "model_notes_tips", params.merge("requested_scope" => "project"), scope: "project"))
      expect(note.composed(root: root).now.gone).to be(true)
      expect(files(note)).to eq([[File.join(project, "model_notes_tips.md"), :base, nil]])
    end

    it "is nil where #fetch is: chi's own text, a folder outside the root" do
      expect(described_class.of_part(part("base", nil, nil)).composed(root: root)).to be_nil
      expect(described_class.of_part(part("preloads", "style", params.merge("system_dir" => dir))).composed(root: root)).to be_nil
    end
  end
end
