# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/pages"
require "samagotchi/pages/launch"
require_relative "support/bundle_pages"

# Pages a bundle ships (a manifest's pages:, Pages::Bundled): listed and run
# as the owner's own, shadowed by the owner's NAME.rb, never removed.
RSpec.describe Samagotchi::Pages::Bundled do
  include BundlePages

  let(:tmp) { Dir.mktmpdir("pages-bundled") }
  let(:pages) { Samagotchi::Pages }
  let(:store) { Samagotchi::Pages::Store }

  around do |example|
    with_env("XDG_CONFIG_HOME" => File.join(tmp, "config"), "XDG_STATE_HOME" => File.join(tmp, "state")) { example.run }
  ensure
    FileUtils.rm_rf(tmp)
  end

  def own(name, body) = FileUtils.mkdir_p(pages.scripts_dir) && File.write(pages.user_script_path(name), body)

  it "lists a bundle's page with no pages folder, and runs it there" do
    scripts = install_page_bundle
    expect(described_class.all.map(&:to_h)).to eq([{ name: "board", bundle: "pager", file: "board.rb",
                                                     path: File.join(scripts, "board.rb") }])
    expect(File.exist?(pages.scripts_dir)).to be(false)
    listed = store.list
    expect(listed.map { |page| [page.name, page.bundle, page.script, page.state] })
      .to eq([["board", "pager", File.join(scripts, "board.rb"), :never_ran]])

    result = Samagotchi::Pages::Launch.run("board")
    expect(result).to be_ok, result.stderr
    expect(result.page.blocks).to eq([{ "type" => "text", "text" => "bundled" }])
    expect(result.page.bundle).to eq("pager")
  end

  it "runs the owner's own NAME.rb instead: it shadows the bundle's page" do
    install_page_bundle
    own("board", "page 'Mine' do |ui|\n  ui.text 'mine'\nend\n")
    expect(pages.script_path("board")).to eq(pages.user_script_path("board"))
    expect(pages.bundled("board")).to be_nil
    expect(store.list.map { |page| [page.name, page.bundle] }).to eq([["board", nil]])
    expect(Samagotchi::Pages::Launch.run("board").page.blocks.first["text"]).to eq("mine")
  end

  it "refuses to remove a bundle's page and leaves its script; removing the owner's own brings the bundle's back" do
    scripts = install_page_bundle
    Samagotchi::Pages::Launch.run("board")
    expect { store.remove("board") }.to raise_error(Samagotchi::Pages::FromBundle,
                                                    "page board comes with the pager bundle: uninstall the bundle or write your " \
                                                    "own #{Samagotchi::Paths.tilde(pages.user_script_path("board"))}")
    expect(File.file?(File.join(scripts, "board.rb"))).to be(true)
    expect(store.read("board").state).to eq(:ok)

    own("board", "page('Mine') { }\n")
    store.remove("board")
    expect(File.exist?(pages.user_script_path("board"))).to be(false)
    expect(File.file?(File.join(scripts, "board.rb"))).to be(true)
    expect(store.read("board")).to have_attributes(state: :never_ran, bundle: "pager")
  end

  it "runs nothing when the bundle's script isn't as installed: the run fails with the refusal" do
    scripts = install_page_bundle
    File.write(File.join(scripts, "board.rb"), "page('Edited') { |ui| ui.text 'edited' }\n")
    result = Samagotchi::Pages::Launch.run("board")
    expect(result).not_to be_ok
    expect(result.page.error.message).to eq("bundle pager's scripts/board.rb differs from the installed one (reinstall the bundle)")
    expect(result.page.blocks).to eq([])
  end

  it "lists none from a bundle this chi is too old for" do
    install_page_bundle(requires_chi: ">= 999.0.0", force: true)
    expect(described_class.all).to eq([])
    expect(store.list).to eq([])
  end
end
