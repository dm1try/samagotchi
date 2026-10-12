# frozen_string_literal: true

require "samagotchi/row_refs"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Samagotchi::RowRefs do
  let(:jira) do
    { kind: "issue", target: { id: "JIRA-1" }, label: "JIRA-1 Login fails",
      actions: [{ id: "open", label: "Open in Jira", url: "https://jira.test/browse/JIRA-1" }] }
  end
  let(:call) { { name: "ticket", args: { "id" => "JIRA-1" } } }
  let(:logged) { [] }

  before do
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    allow(Samagotchi::Log).to receive(:warn).with(:plugins, anything, anything) { |_, event, **f| logged << [event, f] }
  end

  describe ".for" do
    def refs_for(result = nil, cwd: "/proj", &fn)
      described_class.for(fn || ->(_call) { result }, call, cwd: cwd)
    end

    it "gives the lambda the call and keeps its refs as Ref#to_h, in order" do
      seen = nil
      refs = refs_for(cwd: "/proj") do |c|
        seen = c
        [jira, { kind: "file", target: { path: "/proj/lib/a.rb", line: 3 } }]
      end

      expect(seen).to equal(call)
      expect(refs).to eq([Samagotchi::Ref.from(jira).to_h, { kind: "file", target: { path: "/proj/lib/a.rb", line: 3 }, actions: [] }])
      expect(logged).to be_empty
    end

    it "gives none for a tool without the lambda, or a lambda that returns nil or []" do
      expect(described_class.for(nil, call, cwd: "/proj")).to eq([])
      expect(refs_for(nil)).to eq([])
      expect(refs_for([])).to eq([])
      expect(logged).to be_empty
    end

    it "resolves a file ref's relative path against the cwd" do
      expect(refs_for([{ kind: "file", target: { path: "lib/../lib/a.rb" } }]).first[:target]).to eq(path: "/proj/lib/a.rb")
    end

    it "drops a file outside the cwd (and keeps the cwd itself), logging why" do
      refs = refs_for([{ kind: "file", target: { path: "/etc/passwd" } }, { kind: "file", target: { path: "../x.rb" } },
                       { kind: "file", target: { path: "/project/x.rb" } }, { kind: "file", target: { path: "/proj" } }])

      expect(refs.map { |ref| ref[:target][:path] }).to eq(["/proj"])
      expect(logged.map(&:first)).to eq(%w[tool_refs_rejected] * 3)
      expect(logged.first.last).to include(tool: "ticket", reason: a_string_including("outside the session folder"))
    end

    it "with no cwd, drops a relative file and keeps an absolute one" do
      refs = refs_for([{ kind: "file", target: { path: "a.rb" } }, { kind: "file", target: { path: "/x/b.rb" } }, jira], cwd: nil)

      expect(refs.map { |ref| ref[:target] }).to eq([{ path: "/x/b.rb" }, { id: "JIRA-1" }])
    end

    it "drops a bad ref (logged) and keeps the good ones" do
      refs = refs_for([{ kind: "Bad Kind", target: { id: "x" } }, jira,
                       { kind: "issue", target: { id: "y" }, actions: [{ id: "a", label: "A", url: "javascript:alert(1)" }] }, "nope"])

      expect(refs).to eq([Samagotchi::Ref.from(jira).to_h])
      expect(logged.map(&:first)).to eq(%w[tool_refs_rejected] * 3)
    end

    it "drops a ref that isn't a ref at all (junk keys, a nil target) and keeps the others" do
      refs = refs_for([{ 1 => "x" }, { kind: "issue", target: nil }, jira])

      expect(refs).to eq([Samagotchi::Ref.from(jira).to_h])
      expect(logged.map(&:first)).to all(eq("tool_refs_rejected"))
    end

    it "stops at MAX_BYTES of refs (their JSON)" do
      actions = Array.new(8) { |i| { id: "a#{i}", label: "Open #{i}", url: "https://x.test/#{"p" * 1_900}/#{i}" } }
      big = Array.new(10) { |i| { kind: "issue", target: { id: "T-#{i}" }, actions: actions } }
      refs = refs_for(big)

      expect(JSON.generate(refs).bytesize).to be <= described_class::MAX_BYTES
      expect(refs.length).to be < described_class::MAX_REFS
      expect(refs.length).to be_positive
    end

    it "keeps a duplicate once, and at most MAX_REFS" do
      many = Array.new(described_class::MAX_REFS + 5) { |i| { kind: "issue", target: { id: "T-#{i}" } } }

      expect(refs_for([jira, jira]).length).to eq(1)
      expect(refs_for(many).length).to eq(described_class::MAX_REFS)
    end

    it "gives none, logged, for a lambda that raises or returns something that isn't a list" do
      expect(refs_for { raise "boom" }).to eq([])
      expect(refs_for(jira)).to eq([])
      expect(logged.map(&:first)).to eq(%w[tool_refs_failed tool_refs_failed])
      expect(logged.first.last).to include(tool: "ticket", error: "RuntimeError: boom")
    end
  end

  describe "a session folder behind a symlink (macOS /tmp is /private/tmp)" do
    around do |example|
      Dir.mktmpdir("row-refs-") do |dir|
        @real = File.realpath(File.join(dir, "real").tap { |d| FileUtils.mkdir_p(d) })
        @link = File.join(dir, "link")
        File.symlink(@real, @link)
        example.run
      end
    end

    it "takes a path under either spelling and stores the real one; a reload under either keeps it" do
      raw = [{ kind: "file", target: { path: "a.rb" } }, { kind: "file", target: { path: "#{@link}/b.rb" } },
             { kind: "file", target: { path: "#{@real}/c.rb" } }, { kind: "file", target: { path: "#{@link}/../x.rb" } }]
      stored = described_class.for(->(_c) { raw }, call, cwd: @link)

      expect(stored.map { |ref| ref[:target][:path] }).to eq(%W[#{@real}/a.rb #{@real}/b.rb #{@real}/c.rb])
      expect(described_class.for_display(stored, cwd: @link)).to eq(stored)
      expect(described_class.for_display(stored, cwd: @real)).to eq(stored)
    end
  end

  describe ".for_display" do
    it "rebuilds stored refs, dropping what isn't valid any more and files outside the cwd; never raises" do
      stored = [Samagotchi::Ref.from(jira).to_h.transform_keys(&:to_s), { "kind" => "file", "target" => { "path" => "/proj/a.rb" } },
                { "kind" => "file", "target" => { "path" => "/elsewhere/b.rb" } }, { "kind" => "file", "target" => { "path" => "rel.rb" } },
                { "kind" => "issue", "target" => {} }, 42]

      expect(described_class.for_display(stored, cwd: "/proj")).to eq(
        [Samagotchi::Ref.from(jira).to_h, { kind: "file", target: { path: "/proj/a.rb" }, actions: [] }]
      )
      expect(described_class.for_display(nil, cwd: "/proj")).to eq([])
      expect(described_class.for_display("x", cwd: "/proj")).to eq([])
    end
  end
end
