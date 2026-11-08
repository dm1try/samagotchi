# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"

# An installed record with class-file hooks, as a 0.157 install left it:
# manifest.json's "hooks" map (each file's sha256, event, on_error,
# priority), the files in hooks/ and their bases in bases/. chi no longer
# writes one (Provenance#write records no hooks), so a spec of what chi
# does with such a record writes it here, straight to the files.
#
#   legacy_hooks_record("b", hooks: { "h.rb" => "class H; end\n" })
#   legacy_hooks_record("b", hooks: { "h.rb" => { text: nil, meta: { "event" => "before_tool_call" } } },
#                            edited: ["h.rb"])
#
# Each hook is its text (written to hooks/<file>) or a Hash:
#   text:   the bytes to write; nil records the file already in hooks/
#           (a corpus case's installed file or dev link)
#   meta:   the manifest entry's other fields (default event after_turn)
#   sha256: the recorded sha ("" for none); default the file's
#   base:   whether bases/<file> is written (default true)
# +edited+ names hooks whose installed file is then changed, so it no
# longer matches its sha and base. An existing manifest.json (a record the
# spec already installed) gets the map merged in; with none, a minimal
# record is written. A dev record ("dev": true) records "sha256:dev".
module LegacyHooksRecord
  DEFAULT_META = { "event" => "after_turn", "on_error" => "skip", "priority" => 100 }.freeze

  module_function

  # @return [String] the bundle's directory
  def legacy_hooks_record(name, hooks:, edited: [], bundles_dir: Samagotchi::MemoryBundle::Provenance.bundles_dir)
    bundle_dir = File.join(bundles_dir, name)
    manifest_path = File.join(bundle_dir, "manifest.json")
    record = if File.exist?(manifest_path)
               JSON.parse(File.read(manifest_path))
             else
               { "name" => name, "version" => "1.0.0", "scope" => "system", "source" => "",
                 "installed_at" => Time.now.utc.iso8601, "files" => {} }
             end
    map = record["hooks"].is_a?(Hash) ? record["hooks"] : {}
    hooks.each do |file, spec|
      spec = { text: spec } unless spec.is_a?(Hash)
      installed = File.join(bundle_dir, "hooks", file)
      unless spec[:text].nil?
        FileUtils.mkdir_p(File.dirname(installed))
        File.write(installed, spec[:text])
      end
      bytes = File.binread(installed)
      sha = spec.fetch(:sha256) { record["dev"] ? "sha256:dev" : "sha256:#{Digest::SHA256.hexdigest(bytes)}" }
      meta = spec.fetch(:meta, {})
      defaults = meta.key?("events") ? DEFAULT_META.except("event") : DEFAULT_META
      map[file] = { "sha256" => sha }.merge(defaults).merge(meta)
      next unless spec.fetch(:base, true)

      FileUtils.mkdir_p(File.join(bundle_dir, "bases"))
      File.binwrite(File.join(bundle_dir, "bases", file), bytes)
    end
    record["hooks"] = map
    FileUtils.mkdir_p(bundle_dir)
    File.write(manifest_path, JSON.pretty_generate(record))
    edited.each { |file| File.write(File.join(bundle_dir, "hooks", file), "# edited by hand\n") }
    bundle_dir
  end
end
