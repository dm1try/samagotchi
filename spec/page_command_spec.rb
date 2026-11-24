# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/page_command"

# `chi page run | list | rm`: output and exit codes against a temp config
# and state dir. run starts a real runner process.
RSpec.describe Samagotchi::PageCommand do
  let(:tmp) { Dir.mktmpdir("page-command") }
  let(:pages) { Samagotchi::Pages }
  let(:store) { Samagotchi::Pages::Store }
  let(:fixtures) { File.expand_path("fixtures/pages", __dir__) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  around do |example|
    with_env("XDG_CONFIG_HOME" => File.join(tmp, "config"), "XDG_STATE_HOME" => File.join(tmp, "state")) { example.run }
  ensure
    FileUtils.rm_rf(tmp)
  end

  def run(*argv) = described_class.new(argv, stdout: out, stderr: err).run

  def script(name, body)
    FileUtils.mkdir_p(pages.scripts_dir)
    File.write(pages.script_path(name), body)
  end

  def usage_page
    FileUtils.mkdir_p(pages.scripts_dir)
    FileUtils.cp(File.join(fixtures, "usage.rb"), pages.script_path("usage"))
    FileUtils.cp(File.join(fixtures, "usage.json"), pages.scripts_dir)
  end

  it "prints its usage, and refuses an unknown subcommand, a format, a bad name or a stray argument" do
    expect(run).to eq(0)
    expect(out.string).to start_with("Usage: chi page <run|list|rm>")
    expect(run("--help")).to eq(0)
    expect(run("run", "--help")).to eq(0)

    expect(run("show")).to eq(2)
    expect(run("run")).to eq(2)
    expect(run("run", "a", "b")).to eq(2)
    expect(run("run", "Bad_Name")).to eq(2)
    expect(run("run", "usage", "--format", "yaml")).to eq(2)
    expect(run("list", "x")).to eq(2)
    expect(run("rm", "../x")).to eq(2)
    expect(err.string).to include("chi page: unknown subcommand show")
    expect(err.string).to include(%(chi page run: "Bad_Name" isn't a page name))
    expect(File.exist?(pages.state_dir)).to be(false)
  end

  it "names the pages folder the help's run line points at" do
    run("run", "--help")
    expect(out.string).to include("#{File.join(tmp, "config", "samagotchi", "pages")}/NAME.rb")

    with_env("XDG_CONFIG_HOME" => nil) do
      expect(run("run", "--help")).to eq(0)
      expect(out.string).to include("~/.config/samagotchi/pages/NAME.rb")
    end
  end

  describe "run" do
    it "prints the usage page's own numbers and total" do
      usage_page
      expect(run("run", "usage")).to eq(0)
      lines = out.string.lines.map(&:chomp)
      expect(lines[0]).to match(/\Apage usage: "Usage, last 7 days" \(\d+\.\d s\)\z/)
      expect(lines[1..]).to eq(["- text: Stored cost per model. 412 turns.",
                                "- table, 3 rows, columns: Model, Turns, Stored",
                                "    claude:sonnet-5-5 | 96 | $14.2210",
                                "    openrouter:deepseek-v4 | 141 | $3.9042",
                                "    splash:qwen3.8-flash-next | 175 | $0.0000",
                                "    total: Total | 412 | $18.1252"])
    end

    it "prints a text's first 3 lines, a dropped count, :count cells, nil as — and a walk" do
      script("mix", <<~RUBY)
        page "Mix" do |ui|
          ui.text "one\\ntwo\\nthree\\nfour"
          ui.table (1..502).map { |i| { "n" => i, "p" => i * 1500, "x" => nil } }, columns: %w[n p x], format: { "p" => :count }
          ui.walk title: "W", actors: %w[a b], steps: [{ id: 1, actor: "a", does: "x" }, { id: 2, actor: "b", sees: "y" }]
        end
      RUBY
      expect(run("run", "mix")).to eq(0)
      expect(out.string.lines.map(&:chomp)[1..]).to eq(["- text: one", "    two", "    three …",
                                                        "- table, 500 rows (2 dropped), columns: n, p, x",
                                                        "    1 | 1.5k | —", "    2 | 3k | —", "    3 | 4.5k | —",
                                                        '- walk: "W", 2 steps'])
    end

    it "fails naming the line, prints the script's stderr and says the good result is kept" do
      usage_page
      expect(run("run", "usage")).to eq(0)
      script("usage", "warn 'about to fail'\npage 'Usage' do |ui|\n  raise 'boom'\nend\n")

      expect(run("run", "usage")).to eq(1)
      lines = err.string.lines.map(&:chomp)
      expect(lines[0]).to eq("error: line 3: boom")
      expect(lines[1]).to eq("  about to fail")
      expect(lines[2]).to match(/\Athe result of \d{4}-\d\d-\d\d \d\d:\d\d is kept\z/)
      expect(store.read("usage").blocks.size).to eq(2)
    end

    it "prints the stored page as one JSON object" do
      usage_page
      expect(run("run", "usage", "--format", "json")).to eq(0)
      page = JSON.parse(out.string)
      expect(page.keys).to eq(%w[name title blocks ran_at duration_ms script_sha error])
      expect(page["blocks"][1]["total"]).to eq(["Total", 412, 18.1252])
    end

    it "exits 1 for an unknown page and for one already running" do
      expect(run("run", "nope")).to eq(1)
      expect(err.string).to include("chi page run: no page nope")

      script("usage", "page('Usage') { }\n")
      store.locked("usage") { expect(run("run", "usage")).to eq(1) }
      expect(err.string).to include("chi page run: page usage is already running")
    end
  end

  describe "list" do
    it "lists each page's title and state, and changed" do
      usage_page
      run("run", "usage")
      script("broken", "page('Broken') do |ui|\n  raise 'no'\nend\n")
      run("run", "broken")
      script("draft", "page('Draft') { }\n")
      File.write(pages.script_path("usage"), "#{File.read(pages.script_path("usage"))}\n# edited\n")
      out.truncate(0)
      out.rewind

      expect(run("list")).to eq(0)
      expect(out.string.lines.map(&:rstrip).map { |line| line.sub(/\d+ s ago/, "N s ago") })
        .to eq(["broken                      failed N s ago (line 2)",
                "draft   (never ran)",
                "usage   Usage, last 7 days  ran N s ago, changed"])
    end

    it "keeps a title with a newline or a tab on its row" do
      script("multi", "page(\"Two\\nlines\\tand a tab\") { }\n")
      expect(run("run", "multi")).to eq(0)
      out.truncate(0)
      out.rewind

      expect(run("list")).to eq(0)
      expect(out.string.lines.size).to eq(1)
      expect(out.string).to match(/\Amulti  Two lines and a tab  ran \d+ s ago\n\z/)
    end

    it "lists as JSON without the blocks" do
      script("draft", "page('Draft') { }\n")
      expect(run("list", "--format", "json")).to eq(0)
      expect(JSON.parse(out.string)).to eq([{ "name" => "draft", "title" => nil, "ran_at" => nil, "duration_ms" => nil,
                                              "script_sha" => nil, "error" => nil, "state" => "never_ran",
                                              "changed" => false }])
    end

    it "says there are none" do
      expect(run("list")).to eq(0)
      expect(out.string).to start_with("no pages")
    end
  end

  describe "rm" do
    it "removes a page in one line; an unknown one exits 1" do
      script("draft", "page('Draft') { }\n")
      expect(run("rm", "draft")).to eq(0)
      expect(out.string).to eq("removed page draft\n")
      expect(File.exist?(pages.script_path("draft"))).to be(false)

      expect(run("rm", "draft")).to eq(1)
      expect(err.string).to eq("chi page rm: no page draft\n")
    end
  end

  describe ".cell" do
    it "formats money, counts and nil as the page will" do
      expect(described_class.cell(14.221, "money")).to eq("$14.2210")
      expect(described_class.cell(999, "count")).to eq("999")
      expect(described_class.cell(1234, "count")).to eq("1.2k")
      expect(described_class.cell(3_400_000, "count")).to eq("3.4M")
      expect(described_class.cell(nil, "money")).to eq("—")
      expect(described_class.cell("n/a", "money")).to eq("n/a")
    end
  end
end
