# frozen_string_literal: true

require_relative "protected_paths"
require_relative "shell_paths"
require_relative "../paths"
require_relative "../toolkit"
require_relative "../steer"

module Samagotchi
  module Guardrails
    # A participant's turn may only read (D3, D4: it proposes, the owner
    # applies). A core check, on in every guardrails mode and with
    # guardrails.enabled: false, active only while the running turn's author
    # is a participant (GuardrailWiring#checks); the owner's turns never get
    # it. It denies, never asks (nobody on the participant's side may
    # approve, and the owner's approval would be the participant's text
    # acting with the owner's power), every call outside the review kit
    # (Toolkit::REVIEW_TOOLS and the forget layer's forget_outputs):
    #   read: only under the session's project root, and never a file of
    #     the read denylist (chi's state and config dirs, home secret dirs,
    #     project secret files), checked on the path as given and as it
    #     resolves (a symlink in the project to ~/.ssh is ~/.ssh);
    #   memory_read: the project scope only, named (no fallback to system);
    #   anything else, call_tool's real target included: a call_tool of a
    #     built-in reaches the gate as that built-in (ToolRunner#unwrapped),
    #     so what is left of call_tool is a plugin or MCP tool, denied in v1.
    # The declared tools stay the session's (no prompt rebuild per author),
    # so a participant turn's model may still try a write: it is denied
    # here, with the header's "This turn may only read" to keep it rare.
    class ReviewBoundary
      RULE = "review-boundary"
      SOURCE = "core"
      ALLOWED = (Toolkit::REVIEW_TOOLS + %w[forget_outputs]).freeze
      PROJECT_SCOPE = "project"

      # Home folders that hold keys and tokens, never read in a review turn.
      HOME_SECRET_DIRS = %w[.ssh .gnupg .aws].freeze
      # Project files that hold secrets, by basename (and .git/config).
      SECRET_FILE = /\A(?:\.env(?:\..*)?|\.netrc|_netrc|.*\.pem|.*\.key|\.?credentials(?:\.[a-z]+)?)\z/i
      GIT_CONFIG = File.join(".git", "config")

      ADVICE = "This is a participant's review turn: answer from what you can read and propose any change as " \
               "text or a diff for the owner to apply."
      NOT_IN_KIT = "a participant's review turn may only read (read, memory_read, forget_outputs): %s is not allowed"
      OUTSIDE = "a participant's review turn reads only inside the session's project"
      SECRET = "a participant's review turn can't read secrets or chi's own files"
      HOME_ROOT = "a participant's review turn reads only inside a project, and this session's folder is the " \
                  "home folder or above it"
      MEMORY_SCOPE = "a participant's review turn reads project memories only: call memory_read with scope: project"

      # @param author [#call] → String, nil: the running turn's author
      #   (GuardrailWiring#turn_author); the check is off unless it is a
      #   participant's (Steer.participant_author?)
      # @param root [#call] → String, nil: the session's project root (the
      #   work tree top of its folder); nil denies every read
      # @param denied_dirs [#call] → Array<String>: chi's own dirs (state,
      #   config: sessions, grants, the web token, memories and .bundles,
      #   config.yml, hooks)
      # @param home [#call] → String, nil
      def initialize(author:, root:, denied_dirs: -> { ReviewBoundary.chi_dirs }, home: -> { Dir.home })
        @author = author
        @root = root
        @denied_dirs = denied_dirs
        @home = home
      end

      # chi's state dir and config dir, as Paths has them now.
      def self.chi_dirs = [Paths.state_dir, File.join(Paths.config_home, Paths::APP_DIR)]

      # Vote on +verdict+ (its call and targets).
      def check(verdict)
        return verdict unless Steer.participant_author?(@author.call)

        reason = refusal(verdict)
        return verdict unless reason

        verdict.deny!(reason, rule: RULE, source: SOURCE, decided_by: "core", advice: ADVICE)
      end

      private

      def refusal(verdict)
        call = verdict.call || {}
        tool = call[:name].to_s
        return format(NOT_IN_KIT, tool_label(tool, verdict.targets)) unless ALLOWED.include?(tool)

        case tool
        when "read" then read_refusal(verdict.targets&.paths || [])
        when "memory_read" then MEMORY_SCOPE unless call[:scope].to_s.strip.downcase == PROJECT_SCOPE
        end
      end

      # A plugin or MCP tool behind call_tool names what it acts as.
      def tool_label(tool, targets)
        acts_as = targets&.acts_as
        acts_as && acts_as != tool ? "#{tool} (#{acts_as})" : tool
      end

      def read_refusal(paths)
        return OUTSIDE if paths.empty?

        root = @root.call.to_s
        return OUTSIDE if root.empty?

        real_root = ProtectedPaths.real(root)
        home = @home.call.to_s
        return HOME_ROOT if !home.empty? && ShellPaths.within?(ProtectedPaths.real(home), real_root)

        paths.each do |path|
          given = File.expand_path(path)
          real = ProtectedPaths.real(given)
          return OUTSIDE unless ShellPaths.within?(real, real_root)
          return SECRET if secret?(given, home) || secret?(real, home)
        end
        nil
      end

      def secret?(path, home)
        dirs = @denied_dirs.call.compact.map { |dir| File.expand_path(dir) }
        dirs += dirs.map { |dir| ProtectedPaths.real(dir) }
        dirs += HOME_SECRET_DIRS.map { |dir| File.join(home, dir) } unless home.empty?
        return true if dirs.any? { |dir| ShellPaths.within?(path, dir) }

        parts = path.split(File::SEPARATOR)
        parts.any? { |part| SECRET_FILE.match?(part) } || path.end_with?(File::SEPARATOR + GIT_CONFIG) ||
          path.include?("#{File::SEPARATOR}#{GIT_CONFIG}#{File::SEPARATOR}")
      end
    end
  end
end
