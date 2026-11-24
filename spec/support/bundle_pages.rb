# frozen_string_literal: true

require "digest"
require "fileutils"
require "tmpdir"
require "yaml"
require "samagotchi/memory_bundle/installer"

# A bundle that ships page scripts (pages:), installed into the system
# memories of the spec's XDG_CONFIG_HOME (pages_bundled_spec, page_routes_spec,
# page_command_spec). +pages+: script file => its body.
module BundlePages
  PAGE_BODY = "page 'From the bundle' do |ui|\n  ui.text 'bundled'\nend\n"

  # @return [String] the installed bundle's scripts/ folder
  def install_page_bundle(name: "pager", pages: { "board.rb" => PAGE_BODY }, requires_chi: nil, force: false)
    src = Dir.mktmpdir("page-bundle-src")
    FileUtils.mkdir_p(File.join(src, "scripts"))
    pages.each { |file, body| File.write(File.join(src, "scripts", file), body) }
    manifest = { "name" => name, "version" => "1.0.0", "files" => {},
                 "scripts" => pages.to_h { |file, body| [file, "sha256:#{Digest::SHA256.hexdigest(body)}"] },
                 "pages" => pages.keys }
    manifest["requires_chi"] = requires_chi if requires_chi
    File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
    Samagotchi::MemoryBundle::Installer.new(source: src, name: name, scope: "system", strict: true, force: force).run
    Samagotchi::InstalledBundles::Dir.new(name: name).scripts_dir
  ensure
    FileUtils.rm_rf(src) if src
  end
end
