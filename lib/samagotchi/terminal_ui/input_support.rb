# frozen_string_literal: true

require "json"
require "fileutils"
require "reline"

require_relative "../config"
require_relative "../memory_paths"
require_relative "../prompt_history"
require_relative "../tools/memory"
require_relative "../session_commands"
require_relative "line_reader"

module Samagotchi
  class TerminalUI
    # Input the REPL and the attached TUI share: the persistent prompt
    # history, Tab completion (/commands, @path in the cwd, #memory, which
    # inserts #name and the model reads it as typed), multiline reads at the
    # main prompt, and a one-shot prefill of the next read (the default
    # input, a prompt given back after a failed turn).
    #
    # Included for private use; it keeps state in @next_input_prefill and
    # reads @no_default_input.
    module InputSupport
      AT_PATH_COMPLETION_PREFIX = "@"
      MEMORY_COMPLETION_PREFIX = "#"
      AT_PATH_COMPLETION_MAX_CANDIDATES = 200

      private

      # The /commands Tab offers: the session's registry, the REPL's own
      # among them.
      def slash_commands = command_registry.completions(:repl)

      def command_registry = @commands&.registry || SessionCommands.builtin_registry

      # Whether a new session's first read gets the default input
      # (SAMAGOTCHI_DEFAULT_INPUT); --no-default-input says no.
      def default_input_wanted? = !@no_default_input

      # One read at the main prompt. In multiline mode Enter submits, while
      # Meta+Enter/Alt+Enter inserts a newline on terminals that emit that
      # distinct sequence (for example kitty); Tab completes; a queued prefill
      # is typed in first.
      # @return [String, nil] the line, nil on Ctrl-D
      def read_prompt_line(prompt)
        pick_up_history_lines
        input = with_scoped_at_path_completion do
          with_next_input_prefill do
            Reline.readmultiline(prompt, true) { true }
          end
        end
        return nil if input.nil?

        input.gsub(/\r\n?|\n\z/, "\n").strip
      end

      def with_scoped_at_path_completion
        previous_completion_proc = Reline.completion_proc
        previous_autocompletion = Reline.autocompletion
        Reline.autocompletion = true
        Reline.completion_proc = method(:assist_path_completion_candidates).to_proc
        yield
      ensure
        Reline.completion_proc = previous_completion_proc
        Reline.autocompletion = previous_autocompletion
      end

      def assist_path_completion_candidates(word)
        token = word.to_s
        return [] if token.empty?

        if token.start_with?("/")
          return build_slash_completion_candidates(token)
        end

        if token.start_with?(AT_PATH_COMPLETION_PREFIX)
          path_fragment = token.delete_prefix(AT_PATH_COMPLETION_PREFIX)
          return build_project_path_completion_candidates(path_fragment)
        end

        if token.start_with?(MEMORY_COMPLETION_PREFIX)
          memory_fragment = token.delete_prefix(MEMORY_COMPLETION_PREFIX)
          return build_memory_completion_candidates(memory_fragment)
        end

        []
      end

      def build_slash_completion_candidates(slash_fragment)
        fragment = slash_fragment.to_s.strip
        return [] unless fragment.start_with?("/")

        begin
          buf = Reline.line_buffer.to_s
          unless buf.empty?
            return [] unless buf.lstrip.start_with?("/")
          end
        rescue StandardError
          nil
        end

        lowered = fragment.downcase
        return slash_commands.dup if lowered == "/"

        slash_commands.select { |cmd| cmd.start_with?(lowered) }
      rescue StandardError
        []
      end

      def build_project_path_completion_candidates(path_fragment)
        fragment = path_fragment.to_s.tr("\\", "/")
        return [] if fragment.start_with?("/")
        return [] if fragment.split("/").include?("..")

        dir_part = ""
        entry_prefix = fragment

        if fragment.include?("/")
          dir_part = fragment.sub(%r{[^/]*\z}, "")
          entry_prefix = fragment.split("/").last.to_s
        end

        base_dir = dir_part.empty? ? Dir.pwd : File.expand_path(dir_part, Dir.pwd)
        return [] unless path_within_cwd?(base_dir)
        return [] unless File.directory?(base_dir)

        entries = Dir.children(base_dir).sort
        entries.reject! { |entry| entry.start_with?(".") } unless entry_prefix.start_with?(".")
        matches = entries.select { |entry| entry.start_with?(entry_prefix) }

        matches.first(AT_PATH_COMPLETION_MAX_CANDIDATES).map do |entry|
          relative_path = "#{dir_part}#{entry}".tr("\\", "/")
          absolute_path = File.join(base_dir, entry)
          relative_path = "#{relative_path}/" if File.directory?(absolute_path)
          "#{AT_PATH_COMPLETION_PREFIX}#{relative_path}"
        end
      rescue StandardError
        []
      end

      def path_within_cwd?(path)
        expanded = File.expand_path(path)
        cwd = Dir.pwd
        expanded == cwd || expanded.start_with?("#{cwd}#{File::SEPARATOR}")
      end

      def build_memory_completion_candidates(memory_fragment)
        fragment = memory_fragment.to_s.strip.tr("\\", "/")
        candidates = memory_completion_entries
        return candidates.map { |entry| entry[:token] } if fragment.empty?

        candidates.filter_map do |entry|
          entry[:token] if entry[:token].delete_prefix(MEMORY_COMPLETION_PREFIX).start_with?(fragment)
        end
      end

      def memory_completion_entries
        grouped = Hash.new { |hash, key| hash[key] = [] }

        each_memory_completion_entry do |scope, name|
          grouped[name] << scope unless grouped[name].include?(scope)
        end

        grouped.sort_by do |name, scopes|
          [memory_scope_sort_key(scopes.min_by { |scope| memory_scope_sort_key(scope) }), name]
        end.flat_map do |name, scopes|
          scopes = scopes.sort_by { |scope| [memory_scope_sort_key(scope), scope] }
          if scopes.length == 1
            [{ token: "#{MEMORY_COMPLETION_PREFIX}#{name}", scope: scopes.first, name: name }]
          else
            scopes.map do |scope|
              { token: "#{MEMORY_COMPLETION_PREFIX}#{scope}/#{name}", scope: scope, name: name }
            end
          end
        end
      end

      def memory_scope_sort_key(scope)
        scope == "project" ? 0 : 1
      end

      def each_memory_completion_entry
        memory_completion_dirs.each do |scope, dir|
          next unless File.directory?(dir)

          Dir.glob(File.join(dir, "*.md")).sort.each do |path|
            name = File.basename(path, ".md")
            next if name.empty? || name == Tools::MEMORY_INDEX

            yield scope, name
          end
        end
      rescue StandardError
        []
      end

      def memory_completion_dirs
        {
          "project" => File.expand_path(MemoryPaths.project_dir, Dir.pwd),
          "system" => File.expand_path(MemoryPaths.system_dir)
        }
      end

      def load_persistent_history
        @history_lock ||= Mutex.new
        @history_own_lines ||= []
        @history_signature = PromptHistory.signature
        @history_seen = PromptHistory.entries
        @history_seen.last(PromptHistory::LIMIT).each { |entry| Reline::HISTORY << entry }
      rescue StandardError
        nil
      end

      # A scratch session keeps nothing, its typed lines neither.
      def persist_recent_history(input)
        return if @scratch

        own = PromptHistory.normalize([input]).first
        history_lock.synchronize { history_own_lines << own } if own
        begin
          PromptHistory.append(input)
        rescue StandardError
          history_lock.synchronize { forget_own_line(own) } if own
          raise
        end
      rescue StandardError
        nil
      end

      # Before a main-prompt read: the lines other processes (the web,
      # another TUI) added to the history file since we last looked join the
      # ring. Only the file's new tail is appended, so a line this TUI read
      # and didn't persist (/model, !rollback: Reline rings every read) stays
      # put; other processes' lines land after it, the order between the two
      # approximate. Our own appends are skipped (they're in the ring as
      # read). Runs on the reader thread, while the main thread may persist
      # the line just read; @history_own_lines is filled before each append
      # lands, so either way a line is in the ring once. A scratch session
      # keeps Reline's ring as it is.
      #
      # It runs inside LineReader's read, where a Reprompt or Stop lands at
      # once. Both wait until the ring and what we last saw of the file agree
      # (a raise in between would lose the new lines for good), then go on
      # to LineReader; an ordinary error is swallowed.
      def pick_up_history_lines
        return if @scratch

        Thread.handle_interrupt(LineReader::Reprompt => :never, LineReader::Stop => :never) do
          signature = PromptHistory.signature
          next if signature == @history_signature

          entries = PromptHistory.entries
          fresh = PromptHistory.new_tail(@history_seen || [], entries)
          @history_signature = signature
          @history_seen = entries
          history_lock.synchronize { add_others_lines(fresh) }
        rescue StandardError
          nil
        end
      end

      # The lines in +fresh+ go into the ring, except our own (each counted
      # once). Under the history lock.
      def add_others_lines(fresh)
        own = history_own_lines
        fresh.each do |line|
          index = own.index(line)
          next own.delete_at(index) if index

          Reline::HISTORY << line
        end
      end

      def forget_own_line(own)
        index = history_own_lines.rindex(own)
        history_own_lines.delete_at(index) if index
      end

      def history_own_lines
        @history_own_lines ||= []
      end

      # Guards @history_own_lines: the main thread persists lines, the
      # reader thread picks up others'. Never held across file IO.
      def history_lock
        @history_lock ||= Mutex.new
      end

      # The text as given ("Please " keeps its space); a blank one is none.
      def queue_input_prefill(text)
        return if text.to_s.strip.empty?

        @next_input_prefill = text.to_s
      end

      def queue_default_input
        default = default_input_text
        queue_input_prefill(default) if default
      end

      # @return [String, nil] the default input for a new session's first
      #   read, if it gets one
      def default_input_text
        return nil unless default_input_wanted?

        default = Samagotchi::Config.get("default.input")
        return nil if default.nil? || default.strip.empty?

        default
      end

      def consume_input_prefill
        value = @next_input_prefill
        @next_input_prefill = nil
        value
      end

      def with_next_input_prefill
        prefill = consume_input_prefill
        return yield if prefill.nil? || prefill.empty?

        previous_hook = Reline.pre_input_hook
        inserted = false
        Reline.pre_input_hook = proc do
          unless inserted
            Reline.insert_text(prefill)
            inserted = true
          end
          previous_hook.call if previous_hook
        end
        begin
          yield
        ensure
          # Restore only what we replaced: a method-level ensure also ran on the
          # no-prefill early return and reset the hook to nil, dropping the
          # Engine activity hook (with_activity_hook) after the first prompt.
          Reline.pre_input_hook = previous_hook
        end
      end
    end
  end
end
