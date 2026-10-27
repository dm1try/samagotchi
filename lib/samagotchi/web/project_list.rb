# frozen_string_literal: true

require_relative "../paths"
require_relative "../project_scope"
require_relative "push/attention"

module Samagotchi
  module Web
    # Projects represented by the session hub, plus the start project even
    # when it has no sessions.
    module ProjectList
      module_function

      def build(summaries, start_dir:, current_root:)
        start_dir = File.expand_path(start_dir.to_s)
        default_root = ProjectScope.root_for(start_dir)
        groups = {}
        summaries.each do |summary|
          next unless summary.is_a?(Hash) && !summary[:archived]

          root = summary[:project_root]
          next unless valid_root?(root)

          (groups[root] ||= []) << summary
        end
        groups[default_root] ||= [] if valid_root?(default_root)

        rows = groups.map do |root, sessions|
          default = root == default_root
          {
            name: File.basename(root),
            root: root,
            root_label: Paths.tilde(root),
            dir: default ? start_dir : root,
            sessions: sessions.size,
            waiting: sessions.count { |summary| Push::Attention.waits?(summary) },
            updated_at: sessions.map { |summary| summary[:updated_at] }.compact.max_by(&:to_s),
            default: default,
            current: root == current_root
          }
        end
        defaults, others = rows.partition { |row| row[:default] }
        defaults + others.sort_by { |row| [row[:updated_at].to_s, row[:root]] }.reverse
      end

      def valid_root?(root)
        root && File.directory?(root) && ProjectScope.root_for(root) == root
      end
      private_class_method :valid_root?
    end
  end
end
