# frozen_string_literal: true

require "digest"
require "yaml"

module Samagotchi
  module MemoryBundle
    # A bundle manifest's sha256 lines, recomputed from the files they name:
    # `rake bundles:sha` for the shipped bundles and `chi bundle check --fix`
    # for anyone's. Plain Ruby (no chi requires), so the release tools load
    # it on their own.
    module Shas
      class Error < StandardError; end

      # A sha line that doesn't match its file: +old+ is the hex the line
      # holds ("" for a placeholder `sha256: sha256:`), nil when the entry
      # has no sha line at all (a plugin:, hooks: or scripts: entry the
      # installer then takes unchecked; .refresh can't write one).
      Stale = Data.define(:file, :old, :new)

      # What may follow a sha value on its line: a comment, then the line end
      # (\r\n kept as it was).
      TAIL = /(?:[ \t]+#[^\r\n]*)?[ \t]*\r?\n?\z/
      # A sha value with what follows it, for the rewrite.
      VALUE = /sha256:(\h*)((?:[ \t]+#[^\r\n]*)?)[ \t]*(\r?\n?)\z/

      module_function

      # The manifest text with every sha256 line recomputed from the file it
      # names, the layout otherwise untouched. The shapes:
      #   files:            a.md: sha256:<hex>             (dir/a.md)
      #                     a.md:\n    sha256: sha256:<hex> (dir/a.md, with description:)
      #   hooks:            h.rb:\n    sha256: sha256:<hex> (dir/hooks/h.rb)
      #   plugin:           file: p.rb\n  sha256: sha256:<hex> (dir/p.rb)
      #   scripts:          s.rb: sha256:<hex>             (dir/scripts/s.rb)
      # Returns [text, [[relative file, old sha, new sha], ...]] for the lines
      # that changed. +text+ defaults to dir/manifest.yml. A named file that's
      # missing raises, and so does a files: entry none of those shapes
      # matched (a quoted sha, a flow mapping), which would otherwise be
      # skipped without a word.
      def refresh(dir, text = File.read(File.join(dir, "manifest.yml")))
        text, changes, = scan(dir, text)
        [text, changes]
      end

      # The stale sha lines of the bundle at +dir+, then the plugin:, hooks:
      # and scripts: entries with no sha line, as [Stale].
      def stale(dir, text = File.read(File.join(dir, "manifest.yml")))
        _, changes, unlined = scan(dir, text)
        changes.map { |file, old, new| Stale.new(file, old, new) } +
          unlined.map { |file| Stale.new(file, nil, digest(dir, file)) }
      end

      def scan(dir, text)
        parsed = YAML.safe_load(parseable(text)) || {}
        plugin_file = parsed.dig("plugin", "file")
        top = sub = nil
        changes = []
        seen = []
        lines = text.lines.map do |line|
          if line.match?(/\A[^\s#]/)
            top = line[/\A([^\s#][^:]*):/, 1]
            sub = nil
          end
          sub = line[/\A  ([^\s#][^:]*):/, 1] if line.match?(/\A  [^\s#]/)
          file, prefix = sha_line(line, top, sub, plugin_file)
          next line unless file

          seen << file
          _, old, comment, eol = line.match(VALUE).to_a
          new = digest(dir, file)
          changes << [file, old, new] unless old == new
          "#{prefix}sha256:#{new}#{comment}#{eol}"
        end
        unread = keys(parsed["files"]) - seen
        unless unread.empty?
          raise Error, "#{File.basename(dir)}/manifest.yml: no sha line to refresh for files: #{unread.join(", ")} " \
                       "(write `name: sha256:<hex>`, or a mapping with an unquoted `sha256: sha256:<hex>` line)"
        end
        [lines.join, changes, coded(parsed, plugin_file) - seen]
      end
      private_class_method :scan

      # +text+ with each placeholder `sha256: sha256:` given a hex digit: a
      # value that ends in a colon isn't YAML. Manifest readers that should
      # take a placeholder (`chi bundle check`) parse this text.
      def parseable(text) = text.gsub(/^(\s*(?:["']?[^"':\s][^"':]*["']?: )?)sha256:(?=[ \t]*(?:#[^\r\n]*)?\r?$)/, "\\1sha256:0")

      # The code files the manifest names (plugin, hooks, scripts), as paths
      # relative to the bundle dir.
      def coded(parsed, plugin_file)
        (plugin_file.is_a?(String) ? [plugin_file] : []) +
          keys(parsed["hooks"]).map { |h| File.join("hooks", h) } +
          keys(parsed["scripts"]).map { |s| File.join("scripts", s) }
      end
      private_class_method :coded

      def keys(section) = section.is_a?(Hash) ? section.keys.map(&:to_s) : []
      private_class_method :keys

      def digest(dir, file)
        path = File.join(dir, file)
        raise Error, "#{File.basename(dir)}/manifest.yml names #{file}, which isn't there" unless File.file?(path)

        Digest::SHA256.hexdigest(File.binread(path))
      end
      private_class_method :digest

      # [file relative to the bundle dir, the line up to its sha256: value] for a
      # sha line, nil for any other line.
      def sha_line(line, top, sub, plugin_file)
        case top
        when "files"
          m = line.match(/\A(    sha256: )sha256:\h*#{TAIL}/) and return sub && [sub.delete("\"'"), m[1]]
          m = line.match(/\A(  ["']?([^"':]+)["']?: )sha256:\h*#{TAIL}/) and [m[2], m[1]]
        when "hooks"
          m = line.match(/\A(    sha256: )sha256:\h*#{TAIL}/) and sub and [File.join("hooks", sub.delete("\"'")), m[1]]
        when "plugin"
          m = line.match(/\A(  sha256: )sha256:\h*#{TAIL}/) and plugin_file and [plugin_file, m[1]]
        when "scripts"
          m = line.match(/\A(  ["']?([^"':]+)["']?: )sha256:\h*#{TAIL}/) and [File.join("scripts", m[2]), m[1]]
        end
      end
      private_class_method :sha_line
    end
  end
end
