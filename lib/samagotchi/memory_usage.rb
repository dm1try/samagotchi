# frozen_string_literal: true

require "json"

require_relative "memory_paths"
require_relative "memory_bundle/index_size"
require_relative "model_notes"
require_relative "session"
require_relative "llm_context_stale"
require_relative "working_set"
require_relative "file_ref"
require_relative "tool_response"
require_relative "tool_output_cut"
require_relative "model_overlay"
require_relative "tools/memory"

module Samagotchi
  # `chi memory usage` (docs/memory.md): what the memories cost and what the
  # saved sessions really read. Reading only: no writes, no model call, no
  # grades and no advice. It is given the entries (MemoryCommand.entries) and
  # the sessions to count, and returns Data values the command prints.
  #
  # A read is a tool run that pairs with its call (LLMContextStale.paired_runs,
  # so both loops' saved shapes count: the chat loop's tool_calls with their
  # tool_call_id, the native loop's call markup with one joined result), of
  # `memory_read` or of `read` on a memory's file. Its cost is the size of the
  # result as it was saved - a cut result counts as it happened, an overlay
  # too - in tokens the way the prompt's own estimate does (characters /
  # context.chars_per_token). A `memory_read` of a comma list splits that one
  # result by share, as WorkingSet.item does.
  #
  # A project memory is credited only with the reads of sessions of this
  # folder's project (MemoryPaths.project_root: worktrees of one repository
  # share it); a system memory with every session's. Sessions are the saved
  # files, so retention limits what can be seen: that is why the header says
  # how many sessions and how many days.
  class MemoryUsage
    # The memory scopes, project first, as `chi memory ls` reports them.
    SCOPES = Tools::VALID_SCOPES
    MEMORY_READ = Tools::MemoryRead::NAME
    FILE_READ = Tools::Read::NAME

    # One memory read at least once in the sessions counted: its tokens (the
    # results' size) and reads, +cut_reads+ of them returned a cut result,
    # +bytes+ its file now (nil: no file) and +size_tokens+ that size (nil
    # when there is no file), +source+ the bundle that owns it.
    Use = Data.define(:name, :scope, :tokens, :reads, :cut_reads, :bytes, :size_tokens, :source) do
      def to_h = super.transform_keys(&:to_s)
    end

    # One scope's index as every prompt pays it: its tokens, the warning
    # limit (0: off), its memory lines, and those naming a memory no counted
    # session read.
    Index = Data.define(:scope, :tokens, :limit, :lines, :unread_lines) do
      def unread_percent = lines.zero? ? 0 : (100.0 * unread_lines / lines).round

      def to_h = { "scope" => scope, "tokens" => tokens, "limit" => limit,
                   "lines" => lines, "unread_lines" => unread_lines, "unread_percent" => unread_percent }
    end

    # A memory of the user's own no counted session read: +bytes+ its file,
    # +tokens+ that size. A candidate, not a verdict.
    Unread = Data.define(:name, :scope, :bytes, :tokens) do
      def to_h = super.transform_keys(&:to_s)
    end

    # Everything the command prints. +sessions+ are the ones counted (no test
    # runs, none without a user message, archived ones included), +skipped+
    # the saved files not counted for that reason, +unreadable+ the files that
    # could not be read; +top+ and +not_read+ are limited to +top+ rows each.
    Report = Data.define(:sessions, :skipped, :unreadable, :days, :indexes, :read_count, :read_tokens, :cut_reads,
                         :read_names, :unknown_names, :top, :not_read, :not_read_count, :not_read_total) do
      def to_h
        {
          "sessions" => sessions, "skipped" => skipped, "unreadable" => unreadable, "days" => days,
          "indexes" => indexes.map(&:to_h),
          "reads" => { "count" => read_count, "tokens" => read_tokens, "cut_reads" => cut_reads,
                       "names" => read_names },
          "top" => top.map(&:to_h),
          "not_read" => { "count" => not_read_count, "total" => not_read_total, "largest" => not_read.map(&:to_h) },
          "unknown_names" => unknown_names
        }
      end
    end

    # The saved sessions to count, each file parsed once (Session.list then
    # Session.load would parse twice and drop corrupt files silently).
    # @return [Array(Array<Session>, Integer)] the sessions and the files that could not be read
    def self.load_sessions(state_dir: Session.default_state_dir)
      sessions = []
      unreadable = 0
      Dir.glob(File.join(state_dir, "*#{Session::FILE_EXT}")).sort.each do |path|
        data = JSON.parse(File.read(path, encoding: "UTF-8"))
        # A project_root that is not a path (a hand-edited file) makes every
        # later step raise, so the file counts as unreadable rather than
        # taking the whole report down.
        raise ArgumentError, "project_root is not a path" unless data["project_root"].nil? || data["project_root"].is_a?(String)

        sessions << Session.from_h(data)
      rescue StandardError
        unreadable += 1
      end
      [sessions, unreadable]
    end

    # @param sessions [Array<Session>] the saved sessions (load_sessions, or a spec's)
    # @param entries [Array<MemoryCommand::Entry>] the memories to report on
    # @param scopes [Array<String>] the scopes to measure their indexes for
    # @param unreadable [Integer] session files that could not be read
    # @param baseline [Array<String>] memories no read is needed for: config.yml's
    #   `memories:` and the system memories every prompt carries
    #   (SystemPrompt::DEFAULT_SYSTEM_MEMORIES). They are in the prompt from the
    #   start, so they are never saved as used or preloaded in the session file.
    # @param root [String] the folder whose project's memories are the project scope
    # @param env [Hash] the XDG env the memories dirs resolve from
    def initialize(sessions:, entries:, scopes: SCOPES, unreadable: 0, baseline: [], root: Dir.pwd, env: ENV,
                   chars_per_token: MemoryBundle::IndexSize.chars_per_token,
                   warn_limit: MemoryBundle::IndexSize.warn_limit)
      @sessions = Array(sessions)
      @entries = Array(entries)
      @scopes = Array(scopes).map(&:to_s)
      @unreadable = unreadable.to_i
      @baseline = Array(baseline).map { |raw| name_of(raw) }
      # The project the report is for, as MemoryPaths keys it (a worktree
      # resolves to its repository's root; both spellings of a path, /var and
      # /private/var, mean the same project).
      @root = expand(MemoryPaths.project_root(File.expand_path(root.to_s)))
      @env = env
      @chars_per_token = chars_per_token.positive? ? chars_per_token.to_f : 4.0
      @warn_limit = warn_limit.to_i
    end

    # @param top [Integer] the rows the report keeps per section
    # @return [Report]
    def report(top: 10)
      known = {}
      gone = {}
      # [scope, name]: a session's used names carry no scope, and another
      # project's can't vouch for this project's memory of the same name.
      used = Set.new(@baseline.flat_map { |name| SCOPES.map { |scope| [scope, name] } })
      times = []
      sessions = 0
      skipped = 0

      @sessions.each do |session|
        if session.test_run || !session.messages.any? { |entry| entry[:role].to_s == "user" }
          skipped += 1
          next
        end

        sessions += 1
        time = time_of(session.updated_at)
        times << time if time
        project = project_session?(session)
        project_dir = project_dir_of(session)

        (Array(session.used_memory_names) + Array(session.preloaded_memory_names)).each do |raw|
          used << ["system", name_of(raw)]
          used << ["project", name_of(raw)] if project
        end

        reads(session, project, project_dir).each do |scope, name, tokens, cut|
          next unless @scopes.include?(scope) # --scope system leaves a project's reads out

          used << [scope, name]
          # A name with no memory behind it (deleted, or a scope nobody asked
          # for) counts in the totals, but never as a row.
          bucket = entry_for(scope, name) ? known : gone
          row = bucket[[scope, name]] ||= { tokens: 0, reads: 0, cut_reads: 0 }
          row[:tokens] += tokens
          row[:reads] += 1
          row[:cut_reads] += 1 if cut
        end
      end

      rows = known.map do |(scope, name), acc|
        entry = entry_for(scope, name)
        Use.new(name: name, scope: scope, tokens: acc[:tokens], reads: acc[:reads], cut_reads: acc[:cut_reads],
                bytes: entry.bytes, size_tokens: entry.bytes ? token_count(entry.bytes) : nil, source: entry.source)
      end.sort_by { |row| [-row.tokens, row.name] }

      unread = @entries.reject { |entry| entry.source || used.include?([entry.scope.to_s, entry.name]) }
                       .sort_by { |entry| [-entry.bytes.to_i, entry.name] }
      not_read = unread.first(top).map do |entry|
        Unread.new(name: entry.name, scope: entry.scope, bytes: entry.bytes, tokens: entry.bytes ? token_count(entry.bytes) : nil)
      end

      Report.new(
        sessions: sessions,
        skipped: skipped,
        unreadable: @unreadable,
        days: times.empty? ? 0 : ((times.max - times.min) / 86_400.0).round,
        indexes: @scopes.map { |scope| index_row(scope, used) },
        read_count: known.sum { |_, acc| acc[:reads] } + gone.sum { |_, acc| acc[:reads] },
        read_tokens: known.sum { |_, acc| acc[:tokens] } + gone.sum { |_, acc| acc[:tokens] },
        cut_reads: known.sum { |_, acc| acc[:cut_reads] } + gone.sum { |_, acc| acc[:cut_reads] },
        read_names: known.size,
        unknown_names: gone.size,
        top: rows.first(top),
        not_read: not_read,
        not_read_count: unread.size,
        not_read_total: @entries.reject(&:source).size
      )
    end

    private

    def entries_by_scope
      @entries_by_scope ||= @entries.to_h { |entry| [entry.scope.to_s, {}] }.tap do |by_scope|
        @entries.each { |entry| by_scope[entry.scope.to_s][entry.name] ||= entry }
      end
    end

    # The entry a counted read's [scope, name] is, nil for a name with no
    # memory now (a deleted one, a scope no entries were asked for).
    def entry_for(scope, name)
      entries_by_scope.fetch(scope, {})[name]
    end

    # One scope's index: its tokens and lines as the prompt pays them, and how
    # many of its memory lines name a memory no counted session read. Only the
    # lines of memories count (MemoryCommand::LINE, and the entries `chi memory
    # ls` finds behind them): a heading or a bold line of prose is neither the
    # denominator nor an unread line.
    def index_row(scope, used)
      text = index_text(scope)
      size = MemoryBundle::IndexSize.of_text(scope, text, chars_per_token: @chars_per_token)
      names = text.each_line.filter_map { |line| (match = MemoryCommand::LINE.match(line)) && match[1] }.uniq
      entries = names.select { |name| entry_for(scope, name) }
      unread = entries.count { |name| !used.include?([scope, name]) }
      Index.new(scope: scope, tokens: size.tokens, limit: @warn_limit, lines: entries.size, unread_lines: unread)
    end

    def index_text(scope)
      raw = Tools::MemoryRead.scoped_index(scope, env: @env)
      ModelNotes.filter_index(raw, scope, env: @env)
    end

    # The reads of one session: [scope, name, tokens, cut?].
    def reads(session, project, project_dir)
      LLMContextStale.paired_runs(session.messages).flat_map do |run|
        call = run.call
        name = call[:name].to_s
        next [] if failed?(run.text)

        if name == MEMORY_READ
          # index.md is not a memory: the model reads it by name now and then,
          # and its cost is the Indexes section above - but it is one of the
          # names the one result is split between, as WorkingSet does.
          found = WorkingSet.found_names(run)
          names = found.reject { |memory| memory.casecmp?(Tools::MEMORY_INDEX) }
          next [] if names.empty?

          tokens = token_count(run.text.length, found.size)
          cut = cut_result?(run.text)
          names.filter_map do |memory|
            scope = scope_of(memory, call[:scope], project_dir)
            scope == "project" && !project ? nil : [scope, memory, tokens, cut]
          end
        elsif name == FILE_READ
          found = memory_file(FileRef.for(name, call, cwd: session.working_directory)&.path, project_dir)
          # A project memory is credited only with this project's sessions.
          next [] if found.nil? || (found.first == "project" && !project)

          [[found.first, found.last, token_count(run.text.length), cut_result?(run.text)]]
        else
          []
        end
      end
    end

    # WorkingSet's rule: an errored or interrupted run touched nothing.
    def failed?(text)
      ToolResponse.interrupted_text?(text) || text.sub(ToolResponse::LEAD, "").lstrip.start_with?("Error")
    end

    # A result the runner cut: one of ToolOutputCut's marker lines is its own
    # line. Reads saved before whole reads hold cut results, so the cut
    # caveat below is one line, not a section; a memory that only mentions
    # "[cut: ..." in its body is not one.
    def cut_result?(text)
      text.to_s.each_line.any? { |line| ToolOutputCut.cut_marker_line?(line) }
    end

    # Which scope a name a session read belongs to: the scope the call gave,
    # else the session's project when its file is there, else system.
    def scope_of(name, scope, project_dir)
      given = scope.to_s
      return given if SCOPES.include?(given)

      project_dir && File.file?(File.join(project_dir, "#{name}.md")) ? "project" : "system"
    end

    # A read of a memory's file: [scope, name], nil for any other file. The
    # session's own project folder (MemoryPaths.key_for_root), since
    # IndexSync.memory_scope knows only the folder chi is running in.
    def memory_file(path, project_dir)
      return nil if path.nil? || !path.end_with?(".md")

      dir = expand(File.dirname(path))
      stem = File.basename(path, ".md")
      return nil if stem.empty? || stem.casecmp?(Tools::MEMORY_INDEX) || stem.start_with?(".")

      if dir == expand(MemoryPaths.system_dir(env: @env))
        ["system", base_memory("system", stem)]
      elsif project_dir && dir == expand(project_dir)
        ["project", base_memory("project", stem)]
      end
    end

    # The memory a file's stem names. A model overlay's file (<base>.<key>.md,
    # ModelOverlay and Tools::MemoryWrite.overlay_files) is a read of the
    # memory it overlays - unless the stem is a memory of its own, which
    # overlay_files also checks: a name with a dot (handoff_x.v2) has an
    # index line, so it is listed by `chi memory ls`.
    def base_memory(scope, stem)
      base = ModelOverlay.base_file_for("#{stem}.md")
      return stem if base.nil?

      named = File.basename(base, ".md")
      # A stem that is a memory of its own keeps its own reads; an orphan
      # overlay (its base is gone) stays the name its file has.
      return stem if entry_for(scope, stem) || entry_for(scope, named).nil?

      named
    end

    def expand(dir)
      File.realpath(dir)
    rescue SystemCallError
      File.expand_path(dir)
    end

    # The project a session belongs to: the root its file stores, or (a file
    # from before the field, or a folder in no repository) the root of the
    # folder it works in.
    def session_project_root(session)
      root = session.project_root ||
             (session.working_directory.to_s.empty? ? nil : MemoryPaths.project_root(File.expand_path(session.working_directory.to_s)))
      root && expand(root)
    end

    def project_dir_of(session)
      root = session_project_root(session)
      root ? File.join(MemoryPaths.projects_dir(env: @env), MemoryPaths.key_for_root(root)) : nil
    end

    # A session of this folder's project (worktrees of one repository share it).
    def project_session?(session)
      session_project_root(session) == @root
    end

    # "system/delegated" is the memory named delegated.
    def name_of(raw)
      File.basename(raw.to_s, ".md").strip
    end

    def token_count(chars, share = 1)
      (chars.to_i / @chars_per_token / share).ceil
    end

    def time_of(value)
      Time.parse(value.to_s)
    rescue StandardError
      nil
    end
  end
end
