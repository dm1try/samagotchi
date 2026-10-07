# frozen_string_literal: true

require "pathname"
require_relative "../session"
require_relative "../context_note"
require_relative "../context_sources"
require_relative "../git_head"
require_relative "../recap_store"
require_relative "tags"

module Samagotchi
  module Broadcast
    # What a broadcast knows about one recipient, from local state only:
    # where it works, what it was started for, its recap, its last prompt
    # and its tags. Built fresh for each broadcast, never stored; P2's
    # triage model reads #to_s.
    # @!attribute folder [String, nil] the session's folder relative to its
    #   project ("../app-fix" for a worktree), nil when it is the project
    #   root; outside a project the whole path, ~ for home
    # @!attribute tags [Array<Tag>]
    ScopeCard = Data.define(:id, :project, :folder, :branch, :title, :tags, :started, :recap, :recent) do
      def to_s
        where = [("folder #{folder}" if folder), ("branch #{branch}" if branch)].compact.join(", ")
        lines = ["project: #{project || "none"}#{" (#{where})" unless where.empty?}"]
        lines << "title:   #{title}" unless title.to_s.empty?
        lines << "tags:    #{tags.map(&:label).join(" · ")}" unless tags.empty?
        lines << "started: #{started}" unless started.to_s.empty?
        lines << "recap:   #{recap}" unless recap.to_s.empty?
        lines << "recent:  #{recent}" unless recent.to_s.empty?
        lines.join("\n")
      end
    end

    # Builds a ScopeCard for a Recipient.
    module ScopeCards
      STARTED_CHARS = 300
      RECAP_CHARS = 400
      RECENT_CHARS = 200

      module_function

      # @param recipient [Recipient]
      # @param ticket [Regexp] the ticket pattern (Tags.ticket_regexp)
      # @return [ScopeCard]
      def build(recipient, state_dir:, ticket:)
        session = Session.load(recipient.id, state_dir: state_dir)
        prompts = user_texts(session.messages)
        branch = GitHead.branch(session.working_directory)
        sources = ContextSources.attached(session.id, project_root: session.project_root, state_dir: state_dir)
                                .map { |attached| [attached.name, attached.source.hint] }
        ScopeCard.new(id: session.id, project: recipient.project && File.basename(recipient.project),
                      folder: folder(session.working_directory, recipient.project), branch: branch,
                      title: recipient.desc, tags: Tags.of_session(branch: branch, messages: prompts, sources: sources,
                                                                   ticket: ticket),
                      started: cut(prompts.first, STARTED_CHARS),
                      recap: cut(RecapStore.read(Session.session_dir(session.id, state_dir: state_dir))&.dig(:text),
                                 RECAP_CHARS),
                      recent: cut(session.last_prompt, RECENT_CHARS))
      end

      # The user's own messages, as text (an image part leaves its text).
      def user_texts(messages)
        messages.filter_map do |message|
          next unless message[:role].to_s == "user"

          content = message[:content]
          text = if content.is_a?(Array)
                   content.filter_map { |part| part.is_a?(Hash) ? part[:text] || part["text"] : nil }.join("\n")
                 else
                   content.to_s
                 end
          text unless text.strip.empty?
        end
      end
      private_class_method :user_texts

      # Both paths resolved first: a linked worktree's project root comes
      # back resolved (/private/tmp/… on macOS) while the session's folder
      # may go through a symlink (/tmp/…).
      def folder(cwd, project)
        return ContextNote.home_relative(cwd) if project.nil?

        cwd = real(cwd)
        project = real(project)
        return nil if cwd == project

        Pathname.new(cwd).relative_path_from(Pathname.new(project)).to_s
      rescue ArgumentError
        cwd
      end
      private_class_method :folder

      def real(path)
        File.realpath(path.to_s)
      rescue SystemCallError
        File.expand_path(path.to_s)
      end
      private_class_method :real

      def cut(text, limit)
        line = text.to_s.gsub(/\s+/, " ").strip
        line.length > limit ? "#{line[0, limit - 1]}…" : line
      end
      private_class_method :cut
    end
  end
end
