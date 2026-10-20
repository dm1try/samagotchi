# frozen_string_literal: true

require "yaml"
require "samagotchi/testing/rspec"

# The model-notes bundle (lib/samagotchi/bundles/model-notes): its notes
# install cleanly, keep the shape a shipped note needs, and load for exactly
# the model ids spec/model_ids.yml names, matched as chi matches them.
RSpec.describe "The model-notes bundle", :bundle do
  dir = File.expand_path("..", __dir__)
  table = YAML.safe_load_file(File.join(__dir__, "model_ids.yml"))
  manifest = YAML.safe_load_file(File.join(dir, "manifest.yml"))
  notes = Dir.glob(File.join(dir, "model_notes_*.md")).sort

  let(:limits) { sandbox.model_note_limits }

  def install(dir) = Samagotchi::Testing::Install.run(dir, sandbox: sandbox, force: true)

  it "ships at least one note, each listed in files: with a description" do
    expect(notes).not_to be_empty
    listed = manifest.fetch("files")
    notes.each do |path|
      entry = listed[File.basename(path)]
      expect(entry).to be_a(Hash), "#{File.basename(path)} is not listed in files: with a description"
      expect(entry["description"].to_s.strip).not_to be_empty
    end
  end

  it "installs every note into the system scope with no warnings" do
    result = install(dir)
    expect(result.warnings).to eq([])
    expect(result.failures).to eq([])
    notes.each { |path| expect(File.read(File.join(sandbox.memory_dir, File.basename(path)))).to eq(File.read(path)) }
  end

  notes.each do |path|
    name = File.basename(path, ".md")

    describe name do
      text = File.read(path, encoding: "UTF-8")
      body = text.sub(/\A[^\n]*\n?/, "").strip

      it "starts with a models: line, has no dot in its name and is in the second person" do
        expect(text.lines.first).to match(/\Amodels: \S/)
        expect(name).not_to include(".")
        first_person = body.lines.grep(/\b(I|my|me|I'm|I've)\b/)
        expect(first_person).to eq([]), "a shipped note talks to the model (you), not as it"
      end

      it "stays under the size chi warns over" do
        expect(body.length).to be <= limits[:note]
      end

      # A tool a note names (a snake_case word, or one word in backticks)
      # must be one chi declares: a renamed or aliased tool makes the note
      # stale (the bash -> execute alias made the old Mistral note moot).
      it "names only tools chi declares" do
        tools = load_bundle(dir).tools.names
        named = body.scan(/\b[a-z]+(?:_[a-z]+)+\b/).reject { |word| word.start_with?("model_notes_") } +
                body.scan(/`([a-z_]+)`/).flatten
        expect(named.uniq - tools).to eq([])
      end
    end
  end

  describe "which ids load which notes" do
    before { install(dir) }

    table.fetch("rows").each do |row|
      it "#{row.fetch("id")} → #{row.fetch("notes").inspect}" do
        loaded = sandbox.model_notes_for(row.fetch("id"), small: row.fetch("small"))
        expect(loaded.map(&:name)).to eq(row.fetch("notes"))
      end
    end

    it "loads more than one note only for an id listed in expected_overlaps, within the total size chi warns over" do
      overlaps = table.fetch("expected_overlaps")
      table.fetch("rows").each do |row|
        loaded = sandbox.model_notes_for(row.fetch("id"), small: row.fetch("small"))
        expect(loaded.sum(&:chars)).to be <= limits[:total]
        next if loaded.size < 2

        expect(overlaps[row.fetch("id")]).to eq(loaded.map(&:name)), "#{row.fetch("id")} loads #{loaded.map(&:name)}"
      end
    end
  end
end
