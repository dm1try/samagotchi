# frozen_string_literal: true

require_relative "working_set"
require_relative "tools/memory"

module Samagotchi
  module WorkingSet
    # Where a held text came from and how to fetch it again (the plan's D1):
    # the one resolver behind every "now" the working set shows. +origin+
    # says whose record it is, and the guard follows it (the two are not
    # the same and must stay apart):
    #   :run     a memory_read run's stamp entry (+params+: the entry, +ref+:
    #            the name; WorkingSet.memory_now). Resolved with chi web's own
    #            folder (+root+), any saved system_dir ignored; an older
    #            path-only stamp (or one whose project folder is outside the
    #            root) reads its stamped paths; the paths read must pass
    #            MemoryGuard.memory_paths?.
    #   :prompt  a prompt part's saved params (PromptPart#params; +kind+ the
    #            part's, +ref+ its ref; WorkingSetPart). A memory resolves
    #            with the saved system_dir and project_dir, each inside
    #            +root+, and the composer the build used (MemoryRead.compose,
    #            ModelNotes.body_at), so an unchanged memory's text is the
    #            item's byte for byte; an AGENTS.md only on the session
    #            folder's own chain (+cwd+); an appended file never (its path
    #            came with a run's flags); base, the kit, a plugin's section,
    #            an index and the session lines are chi's own text.
    # #fetch has three outcomes: nil (refused, or nothing to fetch), a Now
    # with gone (the source is gone), a Now with its text (diff nil).
    # Not loaded with WorkingSet (the testing kit's file budget,
    # sandbox_spec): WorkingSet.memory_now requires it when it runs.
    Locator = Data.define(:origin, :kind, :ref, :scope, :params)

    class Locator
      # The prompt kinds whose text is a memory's.
      MEMORY_KINDS = %w[identity preloads notes].freeze
      # The prompt kinds a locator fetches.
      FETCHED = (MEMORY_KINDS + %w[agents]).freeze
      READ = ->(path) { File.read(path, encoding: "UTF-8") }
      GONE = Now.new(text: nil, diff: nil, gone: true)

      # A prompt part's (PromptPart, its saved params).
      def self.of_part(part)
        new(origin: :prompt, kind: part.kind, ref: part.ref, scope: part.scope, params: part.params)
      end

      # A memory_read stamp's entry for +name+.
      def self.of_stamp(name, entry)
        new(origin: :run, kind: MEMORY, ref: name, scope: nil, params: entry)
      end

      # The text now: nil (refused, nothing to fetch), GONE, or a Now with
      # its text. +root+: chi web's memories folder (MemoryPaths.system_dir);
      # +cwd+: the session's folder (an AGENTS.md's chain); +read+: File.read,
      # or a stand-in (a memory's files).
      # @return [Now, nil]
      def fetch(root:, cwd: nil, read: READ)
        return prompt_fetch(root, cwd, read) unless origin == :run

        found = resolve(root: root)
        return found == :gone ? GONE : nil unless found.is_a?(Hash)

        text = body(found, read: read)
        text ? Now.new(text: text, diff: nil, gone: false) : GONE
      end

      # A run's entry as it answers now (:run): the paths to read ({path,
      # overlay}), :gone when no entry answers, nil when refused. Apart from
      # #body so memory_now checks every name before it reads any.
      def resolve(root:)
        entry = params
        return nil unless entry.is_a?(Hash)

        if MemoryGuard.resolution_metadata?(entry)
          resolved = MemoryGuard.resolve_memory(ref, entry, system_dir: root)
          if resolved != :stamped_paths
            return :gone unless resolved

            entry = MemoryGuard.resolved_memory_entry(resolved)
          end
        end
        MemoryGuard.memory_paths?(entry, root) ? entry : nil
      end

      # What memory_read would answer now for a resolved +entry+ (its file
      # and the overlay read with it, as Tools::MemoryRead.call appends
      # it); nil when a file is gone.
      def body(entry, read: READ)
        text = read.call(MemoryGuard.field(entry, :path).to_s)
        overlay = MemoryGuard.field(entry, :overlay)
        return text unless overlay.is_a?(Hash)

        overlay_path = MemoryGuard.field(overlay, :path).to_s
        model_key = Tools::MemoryRead.overlay_key(ref, overlay_path)
        model_key ? Tools::MemoryRead.append_overlay(text, read.call(overlay_path), model_key) : text
      rescue SystemCallError
        nil
      end

      private

      def prompt_fetch(root, cwd, read)
        if MEMORY_KINDS.include?(kind)
          memory_fetch(root, read)
        elsif kind == "agents"
          agents_fetch(cwd)
        end
      end

      # A prompt memory's text with the saved params: no model key or
      # folder is worked out again.
      def memory_fetch(root, read)
        return nil unless params.is_a?(Hash) && MemoryGuard.resolution_metadata?(params)

        system_dir = MemoryGuard.field(params, :system_dir)
        project_dir = MemoryGuard.field(params, :project_dir)
        return nil unless system_dir && MemoryGuard.inside_root?(system_dir, root) &&
                          (project_dir.nil? || MemoryGuard.inside_root?(project_dir, root))
        return nil if ref.to_s.strip.empty? || Tools::MemoryRead.invalid_name?(ref.to_s)

        kind == "notes" ? note_fetch(system_dir, project_dir, root) : read_fetch(system_dir, root, read)
      rescue SystemCallError, ArgumentError
        nil
      end

      # A preload's or identity's text: resolved as memory_read resolves it.
      def read_fetch(system_dir, root, read)
        resolved = MemoryGuard.resolve_memory(ref.to_s, params, system_dir: system_dir)
        return nil if resolved == :stamped_paths
        return GONE unless resolved
        return nil unless MemoryGuard.memory_paths?(MemoryGuard.resolved_memory_entry(resolved), root)

        Now.new(text: Tools::MemoryRead.compose(resolved, read: read), diff: nil, gone: false)
      end

      # A model note's text: its scope's file, its overlay beside it.
      def note_fetch(system_dir, project_dir, root)
        require_relative "model_notes"
        name = ref.to_s
        dir = MemoryGuard.field(params, :requested_scope).to_s == "project" ? project_dir : system_dir
        return nil unless dir

        keys = [MemoryGuard.field(params, :model_key), MemoryGuard.field(params, :fallback_model_key)]
        path = File.join(dir, "#{name}.md")
        overlay = keys.compact.map { |key| key.to_s.strip }.reject(&:empty?).map { |key| File.join(dir, "#{name}.#{key}.md") }
                      .find { |candidate| File.file?(candidate) }
        return nil unless MemoryGuard.memory_paths?({ path: path, overlay: overlay && { path: overlay } }, root)
        return GONE unless File.file?(path)

        text = ModelNotes.body_at(path, keys, dir: dir)
        Now.new(text: text, diff: nil, gone: text.nil?)
      end

      # An AGENTS.md's text, only when it is on +cwd+'s chain.
      def agents_fetch(cwd)
        require_relative "prompt_files"
        path = params.is_a?(Hash) ? params["path"].to_s : ""
        return nil if path.empty? || cwd.to_s.empty?

        chain = PromptFiles.agents_paths(cwd).map { |candidate| real(candidate) }
        return nil unless chain.include?(real(path))

        text = PromptFiles.content(path)
        Now.new(text: text, diff: nil, gone: text.nil?)
      end

      # The same file however it's spelled (/tmp vs /private/tmp on macOS).
      def real(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end
    end
  end
end
