# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require_relative "archive_store"
require_relative "context_move"
require_relative "log"
require_relative "objectives"
require_relative "session"
require_relative "session_chain"
require_relative "session_inbox"

module Samagotchi
  # A session chain's notes/ across a continue. The continue moves the
  # previous link's waiting notes to the new link (.move, the last step
  # of its before_spawn); a continue that fails gives them back (.give_back);
  # the new link's worker adopts a note written to the previous link after
  # the move (.adoption: a writer that resolved the id just before the new
  # link was saved, or an older chi that knows no chain head). A note keeps
  # its file name everywhere: its id, and its place in arrival order.
  #
  # Objectives lists stay where they are: an /objectives note is its own
  # session's (pinned), and the continue's Objectives.carry already took the
  # previous link's newest one into the new link's list.
  module NoteMove
    # The notes a continue writes into its new link itself (the chain note,
    # ChildMove's, the attached context's, the objectives' carry): a failed
    # continue deletes them with the link.
    CONTINUE_SOURCES = [SessionChain::NOTE_SOURCE, ContextMove::NOTE_SOURCE, Objectives::SOURCE].freeze

    module_function

    # Moves +from+'s notes into +to+'s notes/, but not its objectives lists
    # nor the notes a continue into +from+ wrote there (CONTINUE_SOURCES: a
    # link continued before it ever started holds its own chain note, which
    # the new link's own replaces). The rename is the claim: one a worker or
    # another move took meanwhile is skipped. A claimed one
    # (*.json.processing: an old worker took it and never absorbed it, or
    # absorbed it and died before the delete) moves too, un-claimed, logged
    # (notes_moved_claimed): the link is archived, so left there it would be
    # lost, and a note seen twice beats a lost one.
    # @return [Array<String>] the file names moved (un-claimed), oldest first
    def move(from:, to:, state_dir:)
      files = Dir.glob(File.join(notes_dir(from, state_dir), "*.{json,json.processing}"))
                 .sort_by { |file| unclaimed_name(file) }
                 .select { |file| (data = read(file)) && !objectives?(data) && !CONTINUE_SOURCES.include?(data["source"]) }
      moved = rename(files, notes_dir(to, state_dir))
      claimed = files.count { |file| file.end_with?(".processing") && moved.include?(unclaimed_name(file)) }
      Log.info(:worker, "notes_moved_claimed", from: from[0, 8], to: to[0, 8], count: claimed) if claimed.positive?
      Log.info(:worker, "notes_moved", from: from[0, 8], to: to[0, 8], count: moved.size) unless moved.empty?
      moved
    end

    # A failed continue's undo, before its link +from+ is deleted: back to
    # +to+ go the notes it moved (+moved+) and any other sent to the link
    # meanwhile, never one the continue wrote itself (CONTINUE_SOURCES).
    # @return [Array<String>] the file names given back
    def give_back(from:, to:, moved:, state_dir:)
      files = unclaimed(notes_dir(from, state_dir)).select do |file|
        next true if moved.include?(File.basename(file))

        data = read(file)
        data && !objectives?(data) && !CONTINUE_SOURCES.include?(data["source"])
      end
      rename(files, notes_dir(to, state_dir)).tap do |back|
        Log.info(:worker, "notes_given_back", from: from[0, 8], to: to[0, 8], count: back.size) unless back.empty?
      end
    end

    # How far back along the chain a worker adopts (Adoption): the links
    # continued into it, newest first.
    ADOPT_MAX_LINKS = 8

    # What a worker for +session+ adopts from the links before it, nil when
    # there is nothing to adopt from: a first link, a predecessor not
    # archived (checked first: no listing then), or one whose next link
    # (SessionChain.next_of) is another. Else one listing walks back: each
    # archived link whose next link is the one after it, from the newest, up
    # to ADOPT_MAX_LINKS, stopping at one not archived or gone; each is
    # adopted from by the creation of the link that continued it.
    # @param session [Session]
    # @return [Adoption, nil]
    def adoption(session, state_dir:)
      from = session.continues
      return nil unless Session.valid_id?(from) && archived?(from, state_dir)

      sessions = Session.list(state_dir: state_dir, sort: "created_at", order: "asc", include_archived: true)
      byid = sessions.to_h { |s| [s.id, s] }
      nexts = sessions.each_with_object({}) { |s, map| map[s.continues] ||= s.id if s.continues }
      sources = []
      child = session
      while Session.valid_id?(from) && sources.size < ADOPT_MAX_LINKS && sources.none? { |src| src.from == from }
        since = time_of(child.created_at)
        break unless since && nexts[from] == child.id && archived?(from, state_dir)

        sources << Source.new(from: from, since: since.to_i)
        child = byid[from] or break
        from = child.continues
      end
      sources.empty? ? nil : Adoption.new(to: session.id, sources: sources, state_dir: state_dir)
    end

    # A link adopted from (#adoption) and from when (whole seconds: the
    # creation of the link that continued it).
    Source = Data.define(:from, :since)

    # A worker's adoption of the notes the links before it get after their
    # continue: #call on each pass takes them while each link is archived
    # (back in the lists, its notes are its own, and the walk stops there).
    # Only notes from the second the next link was made on (a note's stamp
    # has whole seconds): older ones are from before the continue (a
    # continue made before notes moved left them), and would come days late,
    # out of order with the conversation. They, objectives lists and claimed
    # ones stay, each logged once.
    class Adoption
      def initialize(to:, sources:, state_dir:)
        @to = to
        @sources = sources
        @state_dir = state_dir
        @to_dir = NoteMove.notes_dir(to, state_dir)
        @left = Set.new
      end

      # @return [Array<String>] the file names adopted
      def call
        adopted = []
        @sources.each do |source|
          break unless NoteMove.archived?(source.from, @state_dir)

          adopted.concat(adopt(source))
        end
        adopted
      end

      private

      def adopt(source)
        files = NoteMove.unclaimed(NoteMove.notes_dir(source.from, @state_dir)).reject { |file| @left.include?(file) }
        return [] if files.empty?

        take, leave = files.partition { |file| adoptable?(NoteMove.read(file), source.since) }
        log_left(source, leave)
        NoteMove.rename(take, @to_dir).tap do |adopted|
          Log.info(:worker, "notes_adopted", from: source.from[0, 8], sid: @to[0, 8], count: adopted.size) unless adopted.empty?
        end
      end

      def adoptable?(data, since)
        return false if data.nil? || NoteMove.objectives?(data)

        (time = NoteMove.time_of(data["created_at"])) && time.to_i >= since
      end

      def log_left(source, files)
        return if files.empty?

        @left.merge(files)
        Log.info(:worker, "notes_left_old", from: source.from[0, 8], sid: @to[0, 8], count: files.size)
      end
    end

    def archived?(id, state_dir) = ArchiveStore.archived?(Session.session_dir(id, state_dir: state_dir))

    # @return [Time, nil]
    def time_of(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def notes_dir(id, state_dir) = File.join(Session.session_dir(id, state_dir: state_dir), SessionInbox::NOTES_DIR)

    # The unclaimed note files, oldest first.
    def unclaimed(dir) = Dir.glob(File.join(dir, "*.json")).sort_by { |file| File.basename(file) }

    # @return [Hash, nil] the note file's JSON, nil when it can't be read
    def read(file)
      data = JSON.parse(File.read(file))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def objectives?(data) = data.is_a?(Hash) && (data["objectives"].is_a?(Hash) || data["source"] == Objectives::SOURCE)

    # A note file's name without a claim's ".processing".
    def unclaimed_name(file) = File.basename(file).delete_suffix(".processing")

    # @return [Array<String>] the names renamed into +dir+, un-claimed (one
    #   taken meanwhile is skipped)
    def rename(files, dir)
      return [] if files.empty?

      FileUtils.mkdir_p(dir)
      files.filter_map do |file|
        name = unclaimed_name(file)
        File.rename(file, File.join(dir, name))
        name
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
