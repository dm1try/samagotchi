# frozen_string_literal: true

module Samagotchi
  module MemoryBundle
    # Which of a bundle dir's top-level *.md files are its memories (the
    # ones an install copies into the scope dir, docs/memory.md):
    #   - a manifest whose files: lists any: exactly those (that exist);
    #   - else (no manifest, no files: key, or files: {}): every *.md but a
    #     repo's meta files (README, CHANGELOG, LICENSE, ...), so a bundle
    #     kept in its own git repo doesn't install its README as a memory.
    # A listed file is installed whatever its name: `chi bundle build` of
    # a user's own security.md lists it, and it is a memory.
    # files: {} means "no list" rather than "no memories": shipped bundles
    # with nothing to install write it (mcp), and an external bundle that
    # left the map empty installed its *.md before this rule.
    module MemoryFiles
      # A repo's meta files, by name without extension (case-insensitive).
      REPO_META = %w[readme changelog license licence contributing code_of_conduct security].freeze
      META_EXTENSIONS = %w[.md .markdown .txt].freeze

      module_function

      # @return [Array<String>] the memories' basenames, sorted
      def select(bundle_dir, manifest)
        present = Dir.glob(File.join(bundle_dir, "*.md")).map { |f| File.basename(f) }.sort
        listed = manifest&.files&.keys
        return present & listed if listed && !listed.empty?

        present.reject { |name| repo_meta?(name) }
      end

      # The files: entries that name no top-level *.md of the bundle.
      def unshipped(bundle_dir, manifest)
        listed = manifest&.files&.keys || []
        listed.reject { |name| name.end_with?(".md") && File.file?(File.join(bundle_dir, name)) && !name.include?("/") }
      end

      # Whether +name+ is a repo's meta file: README, README.md,
      # readme.markdown, LICENSE.txt, ...
      def repo_meta?(name)
        base = name.downcase
        ext = META_EXTENSIONS.find { |e| base.end_with?(e) }
        REPO_META.include?(ext ? base.delete_suffix(ext) : base)
      end
    end
  end
end
