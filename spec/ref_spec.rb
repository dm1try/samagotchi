# frozen_string_literal: true

require "samagotchi/ref"

RSpec.describe Samagotchi::Ref do
  let(:pr_diff) { { id: "pr_diff", label: "PR diff", url: "https://github.com/acme/app/pull/4/files#diff-1R11" } }

  describe Samagotchi::RefAction do
    it "keeps an http(s) URL, its id and label stripped" do
      action = described_class.new(id: " pr_diff ", label: " PR diff ", url: " https://x.test/a?b=1#c ")
      expect(action.to_h).to eq(id: "pr_diff", label: "PR diff", url: "https://x.test/a?b=1#c")
      expect(described_class.new(id: "a", label: "A", url: "http://x.test").url).to eq("http://x.test")
    end

    it "refuses any other scheme, a URL without a host, an unparsable or an over-long one" do
      ["javascript:alert(1)", "vscode://file/p/a.rb:1", "data:text/html,x", "mailto:a@b.test", "file:///etc/hosts",
       "/relative", "https://", "https://x.test/a b", "", "https://x.test/#{"a" * 2_000}"].each do |url|
        expect { described_class.new(id: "a", label: "A", url: url) }.to raise_error(ArgumentError), url
      end
    end

    it "needs an id and a label" do
      expect { described_class.new(id: "", label: "A", url: "https://x.test") }.to raise_error(ArgumentError, /id/)
      expect { described_class.new(id: "a", label: " ", url: "https://x.test") }.to raise_error(ArgumentError, /label/)
    end

    it "is built from a plugin's hash, with String or Symbol keys" do
      expect(described_class.from({ "id" => "a", "label" => "A", "url" => "https://x.test" }).url).to eq("https://x.test")
      action = described_class.from(pr_diff)
      expect(described_class.from(action)).to equal(action)
      expect { described_class.from("https://x.test") }.to raise_error(ArgumentError)
    end
  end

  it "is a file ref: a path and its lines as the target, extra actions on top of the kind's own" do
    ref = described_class.new(kind: "file", target: { path: "/p/lib/a.rb", line: 11, end_line: nil, extra: 1 }, actions: [pr_diff])
    expect(ref.to_h).to eq(kind: "file", target: { path: "/p/lib/a.rb", line: 11 },
                           actions: [pr_diff])
    expect(ref.actions.first).to be_a(Samagotchi::RefAction)
  end

  it "is any other kind with an id as the target, an optional label" do
    ref = described_class.from({ "kind" => "issue", "target" => { "id" => "ABC-12" }, "label" => "ABC-12 Login fails",
                                 "actions" => [{ "id" => "open", "label" => "Open in Jira", "url" => "https://jira.test/browse/ABC-12" }] })
    expect(ref.to_h).to eq(kind: "issue", target: { id: "ABC-12" }, label: "ABC-12 Login fails",
                           actions: [{ id: "open", label: "Open in Jira", url: "https://jira.test/browse/ABC-12" }])
    expect(described_class.new(kind: :commit, target: { id: "abc123" }).to_h).to eq(kind: "commit", target: { id: "abc123" }, actions: [])
  end

  it "refuses a bad kind, a target without its key, a bad action and a non-list of actions" do
    expect { described_class.new(kind: "", target: { id: "x" }) }.to raise_error(ArgumentError, /kind/)
    expect { described_class.new(kind: "Is Sue\"", target: { id: "x" }) }.to raise_error(ArgumentError, /kind/)
    expect { described_class.new(kind: "file", target: { line: 3 }) }.to raise_error(ArgumentError, /path/)
    expect { described_class.new(kind: "issue", target: { path: "/p" }) }.to raise_error(ArgumentError, /id/)
    expect { described_class.new(kind: "issue", target: "ABC-12") }.to raise_error(ArgumentError, /target/)
    expect { described_class.new(kind: "issue", target: { id: "x" }, actions: [{ id: "a", label: "A", url: "javascript:x" }]) }
      .to raise_error(ArgumentError, /http/)
    expect { described_class.new(kind: "issue", target: { id: "x" }, actions: pr_diff) }.to raise_error(ArgumentError, /actions/)
  end

  it "keeps a file target's lines only when they are positive numbers, the end only past the start" do
    expect(described_class.new(kind: "file", target: { path: "/p/a.rb", line: "4", end_line: 9 }).target).to eq(path: "/p/a.rb", line: 4, end_line: 9)
    expect(described_class.new(kind: "file", target: { path: "/p/a.rb", line: 0, end_line: 9 }).target).to eq(path: "/p/a.rb")
    expect(described_class.new(kind: "file", target: { path: "/p/a.rb", line: 9, end_line: 9 }).target).to eq(path: "/p/a.rb", line: 9)
  end
end
