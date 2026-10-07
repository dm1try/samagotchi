# frozen_string_literal: true

require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/broadcast/scope_card"
require "samagotchi/broadcast/recipients"

RSpec.describe Samagotchi::Broadcast::ScopeCards do
  let(:tmpdir) { File.realpath(Dir.mktmpdir("broadcast-card")) }
  let(:state_dir) { File.join(tmpdir, "state", "sessions") }
  let(:project) { File.join(tmpdir, "shop") }
  let(:ticket) { Samagotchi::Broadcast::Tags.ticket_regexp(nil) }

  after { FileUtils.rm_rf(tmpdir) }

  # A repo at +project+ with a linked worktree ../shop-pay on +branch+.
  def worktree(branch)
    FileUtils.mkdir_p(File.join(project, ".git", "worktrees", "shop-pay"))
    File.write(File.join(project, ".git", "HEAD"), "ref: refs/heads/main\n")
    File.write(File.join(project, ".git", "worktrees", "shop-pay", "HEAD"), "ref: refs/heads/#{branch}\n")
    dir = File.join(tmpdir, "shop-pay")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, ".git"), "gitdir: #{File.join(project, ".git", "worktrees", "shop-pay")}\n")
    dir
  end

  def make(cwd:, messages:, last_prompt:)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: cwd, test_run: false,
                                    messages: messages).tap do |s|
      s.project_root = project
      s.last_prompt = last_prompt
      s.save(state_dir: state_dir)
    end
  end

  def recipient(session, desc: "shop-pay · fix the retry")
    Samagotchi::Broadcast::Recipient.new(id: session.id, short_id: session.id[0, 8], project: project,
                                         cwd: session.working_directory, desc: desc, live: false, owner: nil)
  end

  it "sums a session up from local state: project, worktree, branch, title, tags, first prompt, recap, last prompt" do
    session = make(cwd: worktree("fix/pay-123-retry"), last_prompt: "now the retry spec",
                   messages: [{ role: "system", content: "prompt" },
                              { role: "user", content: [{ type: "text", text: "Fix the  payments\nretry #{"x" * 400}" },
                                                        { type: "image_url", image_url: { url: "data:x" } }] },
                              { role: "assistant", content: "OK" },
                              { role: "user", content: "spec in https://notion.so/team/prd" }])
    dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "recap.json"), JSON.generate(text: "Fixing the payments retry. Specs next."))
    location = Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir)
    location.add(Samagotchi::ContextSources::Source.new(name: "pr-42", cmd: nil, every_seconds: nil, why: nil,
                                                        hint: "https://github.com/acme/shop/pull/42", scope: "session",
                                                        added_by: "test", created_at: Time.now.iso8601))

    card = described_class.build(recipient(session), state_dir: state_dir, ticket: ticket)

    expect(card).to have_attributes(id: session.id, project: "shop", folder: "../shop-pay", branch: "fix/pay-123-retry")
    expect(card.started.length).to eq(300)
    expect(card.started).to start_with("Fix the payments retry xxx").and end_with("…")
    expect(card.to_s.lines.map(&:chomp)).to eq(
      ["project: shop (folder ../shop-pay, branch fix/pay-123-retry)",
       "title:   shop-pay · fix the retry",
       "tags:    ticket PAY-123 · link notion.so/team/prd · pr acme/shop#42 · link github.com/acme/shop/pull/42",
       "started: #{card.started}",
       "recap:   Fixing the payments retry. Specs next.",
       "recent:  now the retry spec"]
    )
  end

  it "leaves out what a session hasn't got, and names no folder at the project root" do
    session = make(cwd: project, messages: [], last_prompt: "")
    FileUtils.mkdir_p(project)

    card = described_class.build(recipient(session, desc: ""), state_dir: state_dir, ticket: ticket)

    expect(card.to_s).to eq("project: shop")
  end

  # macOS: a session started under /tmp works in /tmp/…, while a linked
  # worktree's project root comes back resolved, /private/tmp/….
  it "names a worktree's folder relative to its project when the session's path goes through a symlink" do
    via = File.join(tmpdir, "via")
    File.symlink(tmpdir, via)
    session = make(cwd: File.join(via, File.basename(worktree("main"))), messages: [], last_prompt: "")

    card = described_class.build(recipient(session, desc: ""), state_dir: state_dir, ticket: ticket)

    expect(card.folder).to eq("../shop-pay")
  end
end
