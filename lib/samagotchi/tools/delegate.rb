# frozen_string_literal: true

require_relative "../client_id"
require_relative "../session"
require_relative "../config"
require_relative "../model_profile"
require_relative "../memory_paths"
require_relative "peers"
require_relative "delegate_wait"
require_relative "../child_reports"

module Samagotchi
  # Loaded on first use: session_manager requires terminal_ui, which
  # requires KernelLoop and so these tools (a require cycle otherwise).
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)

  module Tools
    # Hand a task to a child session: an ordinary chi session in its own
    # worker, started in this session's folder (or cwd:, a worktree or
    # subfolder of the same repository) with the task as its first
    # user message and the `delegated` system memory preloaded. It shows in
    # every list as a child of this one and the user can attach to it. With
    # session:, a follow-up to a child that exists. Only the child's final
    # reply comes back (DelegateWait), never its trace.
    class Delegate
      NAME = "delegate"
      MAX_CHILDREN_KEY = "session.max_children"
      MAX_CHILDREN_DEFAULT = 4
      # A child spawned this many seconds ago counts as running even before
      # its worker holds the owner lock: two delegate calls in one model
      # message come milliseconds apart, and the first child's worker is
      # still starting when the second call counts.
      STARTING_GRACE_SECONDS = 15
      # The memory every child starts with, scoped so a project memory of
      # the same name cannot shadow it.
      CHILD_MEMORIES = [Session::DELEGATE_MEMORY].freeze

      def self.name = NAME

      # @param content [String] the task (the child's user message, verbatim)
      # @param model [String, nil] the child's model (an alias works); the parent's by default
      # @param session [String, nil] a child's id or prefix: send the task there instead
      # @param cwd [String, nil] the new child's folder (child_cwd checks it); the parent's by default
      # @param wait [Boolean, String, nil] wait for the reply (default true)
      # @param timeout [Integer, String, nil] seconds to wait (default DelegateWait::TIMEOUT_DEFAULT)
      # @param peers [Peers, nil]
      def self.call(content, model: nil, session: nil, cwd: nil, wait: nil, timeout: nil, peers: nil)
        return "Error: this session's id is not known here" unless peers&.session_id

        task = content.to_s.strip
        return "Error: give the task, the child's first message" if task.empty?

        sd = peers.state_dir || Session.default_state_dir
        parent = Session.load(peers.session_id, state_dir: sd)
        wait = parse_wait(wait)
        timeout = parse_timeout(timeout)

        cwd = cwd.to_s.strip
        child_id, warning = if session.to_s.strip.empty?
                              start_child(task, parent: parent, model: model, cwd: cwd, state_dir: sd)
                            elsif !cwd.empty?
                              "Error: cwd starts a new child; a follow-up with session keeps the child's folder"
                            else
                              follow_up(task, session: session.to_s.strip, parent: parent, state_dir: sd)
                            end
        return child_id if child_id.start_with?("Error:")

        note = warning ? "Warning: #{warning}\n" : ""
        return note + DelegateWait.call(child_id, peers: peers, timeout: timeout) if wait

        started = session.to_s.strip.empty? ? "Started a delegate session" : "Sent the follow-up to delegate #{child_id[0, 8]}"
        "#{note}session: #{child_id}\nstatus: running\n#{started}; #{running_hint(peers)} " \
          "It shows in chi sessions list and the web as a child of this session; the user can attach to it."
      rescue ArgumentError => e
        "Error: #{e.message}"
      end

      # How the reply of a child left running comes back: a report only
      # reaches a parent that can get one (DelegateWait.reports_mode).
      def self.running_hint(peers)
        case DelegateWait.reports_mode(peers)
        when "off" then "delegate_result waits for its reply."
        when "queue"
          "chi adds its reply to your next turn by itself (a delegate report; you aren't woken while idle); " \
            "don't poll with delegate_result."
        else
          "chi brings its reply to you by itself when it ends its turn (a delegate report), starting a turn for it " \
            "if you are idle. Don't wait for it with delegate_result, also not to collect several children's replies: " \
            "tell your user what started and end your turn, or keep working."
        end
      end
      private_class_method :running_hint

      # @return [String] the new child's id, or an Error: line
      def self.start_child(task, parent:, model:, cwd:, state_dir:)
        if parent.parent_id
          return "Error: this session is a delegate of #{parent.parent_id}; delegated sessions don't delegate further"
        end

        folder = child_cwd(cwd, parent)
        return folder if folder.start_with?("Error:")

        running = running_children(parent.id, state_dir: state_dir)
        max = max_children
        if running.size >= max
          ids = running.map { |s| s[:short_id] }.join(", ")
          return "Error: #{running.size} delegate#{"s" if running.size != 1} of this session #{running.size == 1 ? "is" : "are"} running " \
                 "(the most is #{max}, #{MAX_CHILDREN_KEY}): #{ids}. delegate_result waits for one; `chi sessions stop ID` stops one."
        end

        child = SessionManager.spawn_session(prompt: task, working_directory: folder,
                                             model_name: child_model(model, parent), memories: CHILD_MEMORIES,
                                             parent_id: parent.id, delegate: true, state_dir: state_dir)
        DelegateWait.mark_started(parent.id, child, state_dir: state_dir)
        [child.id, child.model_warning]
      end
      private_class_method :start_child

      # The new child's folder: the parent's, or +cwd+ (relative to the
      # parent's) when it is a folder of the parent's repository, in any of
      # its worktrees (one project_root, from the common git dir). Outside
      # git only a subfolder of the parent's folder. Nothing is created
      # here: the model makes a worktree with execute, where guardrails see it.
      # @return [String] an absolute folder, or an Error: line
      def self.child_cwd(cwd, parent)
        base = parent.working_directory
        return base if cwd.empty?

        folder = File.expand_path(cwd, base)
        return "Error: cwd #{folder} is not a folder (create the worktree first)" unless File.directory?(folder)

        folder = File.realpath(folder)
        unless same_repository?(folder, base)
          return "Error: cwd must be a folder of this session's repository (a worktree or subfolder of it), not #{folder}"
        end
        if MemoryPaths.in_repo?(base) && !work_tree?(folder)
          return "Error: cwd #{folder} is not in a work tree of this session's repository (a git dir, or a bare " \
                 "repository's folder): give a worktree's folder or a subfolder of one"
        end

        folder
      end
      private_class_method :child_cwd

      # A folder git works in: under a checkout's top (work_tree_root), not
      # inside the git dir (.git, .git/objects, a bare layout's .bare), and
      # one `git rev-parse` says is in a work tree (it says false in a bare
      # layout's container too). Read-only; IO.popen, so a spec's
      # Process.spawn stub doesn't catch it.
      def self.work_tree?(folder)
        return false unless MemoryPaths.work_tree_root(folder)

        git_dir = MemoryPaths.git_dir(folder)
        return false if git_dir && within?(folder, File.realpath(git_dir))

        out = IO.popen(["git", "-C", folder, "rev-parse", "--is-inside-work-tree"], err: File::NULL, &:read)
        out.strip == "true"
      rescue SystemCallError
        false
      end
      private_class_method :work_tree?

      def self.within?(path, dir) = path == dir || path.start_with?("#{dir}/")
      private_class_method :within?

      def self.same_repository?(folder, base)
        if MemoryPaths.in_repo?(base)
          MemoryPaths.project_root(folder) == MemoryPaths.project_root(base)
        else
          within?(folder, File.realpath(base))
        end
      rescue SystemCallError
        false
      end
      private_class_method :same_repository?

      # @return [String] the child's id, or an Error: line
      def self.follow_up(task, session:, parent:, state_dir:)
        id = Session.resolve_id(session, state_dir: state_dir)
        child = begin
          Session.load(id, state_dir: state_dir)
        rescue ArgumentError
          return "Error: no session #{session} (list_sessions shows them)"
        end
        unless child.parent_id == parent.id
          return "Error: #{id[0, 8]} is not a delegate of this session; send_note reaches any session"
        end

        # Only a reply after this delivery counts as the follow-up's.
        DelegateWait.mark_seen(parent.id, child, state_dir: state_dir)
        delivered = SessionManager.deliver_turn(id, prompt: task, client_id: "#{ClientId::DELEGATE_PREFIX}#{parent.id[0, 8]}",
                                                    state_dir: state_dir)
        case delivered[:status]
        when :accepted then id
        when :refused then "Error: session #{id[0, 8]} refused the message (#{delivered.dig(:ack, "error")})"
        when :timeout then "Error: the worker of session #{id[0, 8]} did not answer in time, so the message was not sent"
        else "Error: the message to session #{id[0, 8]} could not be written"
        end
      rescue SessionManager::OwnedByTUI
        "Error: session #{id[0, 8]} is open in a chi REPL, which can't take a delegated message"
      rescue Session::AmbiguousId => e
        "Error: #{e.message}"
      end
      private_class_method :follow_up

      # The model as typed (spawn_session stores its resolved ref), else the
      # parent's. No existence check here: spawn_session checks the host
      # (check_host!, its UnknownHost comes back as this tool's Error: line)
      # and warns about an id the host's saved model list doesn't have
      # (ModelProfile.model_warning, added to this tool's result).
      def self.child_model(model, parent)
        return parent.model_name if model.to_s.strip.empty?

        ModelProfile.required_model_name(model.to_s.strip)
      end
      private_class_method :child_model

      # The children of +parent_id+ that count against session.max_children
      # (a plugin's ctx.sessions.fork counts them too).
      # @return [Array<Hash>] SessionManager.children_of rows
      def self.running_children(parent_id, state_dir:)
        SessionManager.children_of(parent_id, state_dir: state_dir).select { |s| running?(s) }
      end

      # busy (a worker runs its turn), or running with a worker on its way
      # (ChildrenStatus asks it too).
      # @param summary [Hash] a children_of row, or the same keys: busy,
      #   status, live, updated_at
      def self.running?(summary)
        return true if summary[:busy]
        return false unless summary[:status] == Session::STATUS_RUNNING && !summary[:live]

        Time.now - Time.iso8601(summary[:updated_at].to_s) < STARTING_GRACE_SECONDS
      rescue ArgumentError
        false
      end

      def self.max_children
        value = Integer(Config.get(MAX_CHILDREN_KEY), exception: false)
        value&.positive? ? value : MAX_CHILDREN_DEFAULT
      rescue StandardError
        MAX_CHILDREN_DEFAULT
      end

      # true unless told otherwise; text-based parsers hand strings over.
      def self.parse_wait(value)
        return true if value.nil? || value.to_s.strip.empty?
        return value if [true, false].include?(value)

        !%w[false 0 no off].include?(value.to_s.strip.downcase)
      end

      # Seconds to wait: 0 (or less) looks once and returns at once; a
      # missing or unreadable value is the default.
      # @return [Integer]
      def self.parse_timeout(value)
        parsed = Integer(value.to_s.strip, exception: false)
        parsed ? [parsed, 0].max : DelegateWait::TIMEOUT_DEFAULT
      end
    end
  end
end
