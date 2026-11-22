# frozen_string_literal: true

require_relative "working_set"
require_relative "llm_context_stale"
require_relative "file_ref"
require_relative "tool_response"
require_relative "tools/memory"

module Samagotchi
  module WorkingSet
    # chi's own changes of files, from a conversation's paired runs: the
    # latest successful one per target still in the stored conversation
    # (so still sent: its arguments carry the text), in conversation order.
    # What tells a prompt part chi changed itself from one someone else
    # changed (WorkingSetPart.states), and a memory chi read then changed
    # from one changed behind it (WorkingSet.build). See
    # docs/internals/working-set.md (Stale prompt parts).
    #
    # - a memory_write with content: keyed [scope, name, nil], or
    #   [scope, name, KEY] for a current_model_only overlay (the key off its
    #   output, "for KEY saved": the handler's model key, never an argument);
    # - a memory_write remove: true whose output says "removed from" (a
    #   file already gone, "its dangling index line was dropped", is none):
    #   the base's target, [scope, name, nil];
    # - an edit or write: its FileRef path, with its stamp.
    # Never a description-only write ("(file unchanged)"), the index
    # (path: "index"), or a failed or interrupted run (WorkingSet.failed?).
    # The scope comes off the output ("saved to project scope"), the scope
    # the handler wrote in.
    #
    # Loaded only with what the testing kit already loads (sandbox_spec's
    # file budget): no ModelNotes, Locator, TextDiff or PromptFiles here.
    class OwnChanges
      # One own change: the run's chi +tool_id+, its +step+
      # (LLMContextStale::PairedRun#step), its entry's +index+ and +place+
      # in the batch, +op+ (memory_write, remove, write, edit), a
      # memory_write's +content+, a file tool's +stamp+ ({mtime_ns:, size:},
      # nil without one), an exact-match edit's +undo+ ([old_text,
      # new_text]; nil for a range edit, an empty new_text, a write).
      Change = Data.define(:tool_id, :step, :index, :place, :op, :content, :stamp, :undo) do
        # Conversation order.
        def order = [index, place]

        def to_h = { tool_id: tool_id, step: step, op: op }
      end

      MEMORY_WRITE = "memory_write"
      REMOVE = "remove"
      FILE_TOOLS = %w[write edit].freeze
      SAVED = /\AMemory '.*' saved to (project|system) scope/
      OVERLAY = /\AModel overlay '.*' for ([a-z0-9-]+) saved to (project|system) scope/
      REMOVED = /\AMemory '.*' removed from (project|system) scope/

      # @param runs [Array<LLMContextStale::PairedRun>] the conversation's
      #   paired runs (WorkingSet.build has them already: no second walk)
      # @param conversation [Array<Hash>] the entries they came from (a
      #   file tool's stamp sits on its tool_response entry)
      # @param cwd [String, nil] the session's folder (FileRef)
      def self.from_runs(runs, conversation, cwd:)
        memories = {}
        files = {}
        runs.each do |run|
          # The name first: failed? copies the output, and most runs are no own change at all.
          name = run.call[:name].to_s
          next unless name == Tools::MemoryWrite::NAME || FILE_TOOLS.include?(name)
          next if WorkingSet.failed?(run.text)

          if name == Tools::MemoryWrite::NAME
            target, change = memory_change(run)
            memories[target] = change if target
          elsif FILE_TOOLS.include?(name)
            path = FileRef.for(name, run.call, cwd: cwd)&.path
            (files[File.expand_path(path)] ||= []) << file_change(run, conversation) if path
          end
        end
        new(memories, files)
      end

      # chi web's: one paired_runs walk of +conversation+.
      def self.of(conversation, cwd:)
        conversation = Array(conversation)
        from_runs(LLMContextStale.paired_runs(conversation), conversation, cwd: cwd)
      end

      def self.memory_change(run)
        name = run.call[:path].to_s.strip
        return nil if name.empty? || name == Tools::MEMORY_INDEX

        body = run.text.to_s.sub(ToolResponse::LEAD, "").lstrip
        change = ->(op, content = nil) { change(run, op, content: content) }
        if (match = SAVED.match(body))
          [[match[1], name, nil], change.call(MEMORY_WRITE, run.call[:content].to_s)]
        elsif (match = OVERLAY.match(body))
          [[match[2], name, match[1]], change.call(MEMORY_WRITE, run.call[:content].to_s)]
        elsif (match = REMOVED.match(body))
          [[match[1], name, nil], change.call(REMOVE)]
        end
      end

      def self.file_change(run, conversation)
        entry = conversation[run.index]
        stamps = entry.is_a?(Hash) ? entry[:tool_stamps] || entry["tool_stamps"] : nil
        stamp = stamps.is_a?(Array) ? stamps[run.ref.run] : nil
        stamp = nil unless stamp.is_a?(Hash) && (stamp.key?(:mtime_ns) || stamp.key?("mtime_ns"))
        call = run.call
        exact = call[:name].to_s == "edit" && call[:start_line].nil? && !call[:old_text].to_s.empty? && !call[:new_text].to_s.empty?
        change(run, call[:name].to_s, stamp: stamp, undo: exact ? [call[:old_text].to_s, call[:new_text].to_s] : nil)
      end

      def self.change(run, op, content: nil, stamp: nil, undo: nil)
        Change.new(tool_id: run.ref.id, step: run.step, index: run.index, place: run.ref.run, op: op, content: content,
                   stamp: stamp, undo: undo)
      end

      private_class_method :memory_change, :file_change, :change

      def initialize(memories, files)
        @memories = memories
        @files = files
      end

      def empty? = @memories.empty? && @files.empty?

      # The latest own change of the memory +name+ in +scope+ (+key+: its
      # overlay's; a remove counts for the overlays too: it moves them).
      # @return [Change, nil]
      def memory(scope, name, key: nil)
        base = @memories[[scope, name, nil]]
        return base unless key

        own = @memories[[scope, name, key]]
        removed = base if base&.op == REMOVE
        [own, removed].compact.max_by(&:order)
      end

      # The latest own change of one file a part was read from
      # (WorkingSet::Locator::Source's +path+, +role+, +key+): a memory's by
      # its folder among +dirs+ ({"project" => dir, "system" => dir}, the
      # part's saved ones: the scope is the folder the file sits in, never a
      # prefix test, as a project's folder is inside the system one) and its
      # name, and an edit or write of that file (by basename, then realpath);
      # the later of the two.
      # @return [Change, nil]
      def for_file(path, role:, key: nil, dirs: {})
        [memory_of_file(path, role: role, key: key, dirs: dirs), file(File.expand_path(path.to_s))].compact.max_by(&:order)
      end

      # The latest memory_write (or remove) of the memory file at +path+, by
      # its folder among +dirs+ (#for_file's rule), or nil.
      # @return [Change, nil]
      def memory_of_file(path, role:, key: nil, dirs: {})
        path = File.expand_path(path.to_s)
        folder = File.dirname(path)
        scope = dirs.find { |_, dir| dir && File.expand_path(dir.to_s) == folder }&.first
        scope && memory(scope, memory_name(path, role, key), key: role == :overlay ? key : nil)
      end

      # The latest edit or write of the file at +path+.
      # @return [Change, nil]
      def file(path) = file_history(path).last

      # Every edit and write of the file at +path+, in conversation order.
      # @return [Array<Change>]
      def file_history(path)
        base = File.basename(path)
        wanted = real(path)
        @files.select { |candidate, _| File.basename(candidate) == base && real(candidate) == wanted }.values.flatten.sort_by(&:order)
      end

      # Whether undoing chi's edits in +history+ (Change, conversation
      # order), newest first, takes +now+ back to +sent+: each one's
      # new_text found exactly once and put back to its old_text, and the
      # text equal to +sent+ (stripped, as a prompt file's is) after one of
      # them. A range edit, an empty new_text, a write or a text it can't
      # find stops it: false. Proves chi's edits are all that changed the
      # file since it was sent (an edit over a change chi never saw is not).
      # +written+: chi's memory_write of the file before those edits; its
      # content, reached by undoing the edits after it, holds too (chi has
      # it whole).
      def self.undoes_to?(now, sent, history, written: nil)
        text = now.to_s
        history.reverse_each do |change|
          return text == written.content if written && (change.order <=> written.order).negative?

          old_text, new_text = change.undo
          return false unless change.op == "edit" && new_text && text.scan(new_text).size == 1

          text = text.sub(new_text) { old_text }
          return true if text == sent || text.strip == sent.to_s.strip
        end
        !written.nil? && text == written.content
      end

      # Whether the file at +path+ still holds what +change+ left: a
      # memory_write's content byte for byte, a remove's absence, a file
      # tool's stamp (mtime and size, as WorkingSet's stale check compares).
      def current?(change, path, stat: File.method(:stat), read: ->(file) { File.binread(file) })
        case change.op
        when MEMORY_WRITE then read.call(path) == change.content.b
        when REMOVE then !File.exist?(path)
        else change.stamp ? !WorkingSet.differs?(path, change.stamp, stat) : false
        end
      rescue SystemCallError
        false
      end

      private

      def memory_name(path, role, key)
        stem = File.basename(path, ".md")
        role == :overlay && key ? stem.delete_suffix(".#{key}") : stem
      end

      def real(path)
        File.realpath(path)
      rescue SystemCallError, ArgumentError
        File.expand_path(path)
      end
    end
  end
end
