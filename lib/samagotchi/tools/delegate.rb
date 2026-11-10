# frozen_string_literal: true

require_relative "../client_id"
require_relative "../git_env"
require_relative "../session"
require_relative "../config"
require_relative "../model_profile"
require_relative "../memory_paths"
require_relative "../guardrails/context"
require_relative "peers"
require_relative "delegate_wait"
require_relative "../child_reports"
require_relative "../worker_link"

module Samagotchi
  # Loaded on first use (a delegate call): keeps the bundle test kit's load budget
  # (spec/samagotchi/testing/sandbox_spec.rb).
  autoload :WorkerPresence, File.expand_path("../worker_presence", __dir__)

  # Loaded on the first task (a leaf; the bundle test kit's load budget,
  # spec/samagotchi/testing/sandbox_spec.rb).
  autoload :CommandIntake, File.expand_path("../command_intake", __dir__)

  # Loaded on first use: this autoload keeps SessionManager and its ~80
  # files unloaded until the delegate/session path needs them.
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)

  module Tools
    # Hand a task to a child session: an ordinary chi session in its own
    # worker, started in this session's folder (or cwd:, a worktree or
    # subfolder of the same repository) with the task as its first
    # user message and the `delegated` system memory preloaded. It shows in
    # every list as a child of this one and the user can attach to it, on
    # toolkit: (a kit's name) or config's toolkit.child. With session:, a
    # follow-up to a child that exists. Only the child's final
    # reply comes back (DelegateWait), never its trace.
    class Delegate
      NAME = "delegate"
      MAX_CHILDREN_KEY = "session.max_children"
      MAX_CHILDREN_DEFAULT = 4
      # A path in a task: absolute, ~/ or ../, not glued to a word (a URL's
      # /api is not one) and stopping at quotes, backticks or punctuation.
      PATH_TOKEN = %r{(?<![\w./~-])(?:~/|\.\./|/(?!/))[^\s`'"<>()\[\]{},;&|]*}
      # The memory every child starts with, scoped so a project memory of
      # the same name cannot shadow it.
      CHILD_MEMORIES = [Session::DELEGATE_MEMORY].freeze

      def self.name = NAME

      # @param content [String] the task (the child's user message, verbatim)
      # @param model [String, nil] the child's model (an alias works); the parent's by default
      # @param session [String, nil] a child's id or prefix: send the task there instead
      # @param cwd [String, nil] the new child's folder (child_cwd checks it); the parent's by default
      # @param toolkit [String, nil] the new child's toolkit, a kit's name (checked against the parent's
      #   kits, Peers#toolkit_names); config's toolkit.child by default
      # @param wait [Boolean, String, nil] wait for the reply (default true)
      # @param timeout [Integer, String, nil] seconds to wait (default DelegateWait::TIMEOUT_DEFAULT)
      # @param peers [Peers, nil]
      def self.call(content, model: nil, session: nil, cwd: nil, toolkit: nil, wait: nil, timeout: nil, peers: nil)
        return "Error: this session's id is not known here" unless peers&.session_id

        task = content.to_s.strip
        return "Error: give the task, the child's first message" if task.empty?
        # The child's intake takes no shell line from its parent: say so
        # now, so the model rewrites the task (a /word one is the child's text).
        return "Error: #{CommandIntake::REFUSED}" if CommandIntake.shell_line?(task)

        sd = peers.state_dir || Session.default_state_dir
        parent = Session.load(peers.session_id, state_dir: sd)
        wait = parse_wait(wait)
        timeout = parse_timeout(timeout)

        cwd = cwd.to_s.strip
        toolkit = toolkit.to_s.strip
        child_id, warnings = if session.to_s.strip.empty?
                               start_child(task, parent: parent, model: model, cwd: cwd, toolkit: toolkit, state_dir: sd,
                                                 peers: peers)
                             elsif !cwd.empty?
                               "Error: cwd starts a new child; a follow-up with session keeps the child's folder"
                             elsif !toolkit.empty?
                               "Error: toolkit starts a new child; a follow-up keeps the child's toolkit"
                             else
                               follow_up(task, session: session.to_s.strip, parent: parent, state_dir: sd)
                             end
        return child_id if child_id.start_with?("Error:")

        note = Array(warnings).map { |warning| "Warning: #{warning}\n" }.join
        if wait
          started = monotonic
          boot = await_worker(child_id, state_dir: sd, timeout: timeout, cancelled: -> { peers.cancelled? })
          return note + DelegateWait.boot_result(child_id, boot, timeout: timeout, peers: peers) unless boot == :up

          result = DelegateWait.call(child_id, peers: peers, timeout: timeout, waited: monotonic - started)
          return RefText.wrap(note + result, result.respond_to?(:ref_path) ? result.ref_path : nil)
        end

        started = session.to_s.strip.empty? ? "Started a delegate session" : "Sent the follow-up to delegate #{child_id[0, 8]}"
        "#{note}session: #{child_id}\nstatus: running\n#{started}; #{running_hint(peers)} " \
          "It shows in chi sessions list and the web as a child of this session; the user can attach to it."
      rescue ArgumentError, Toolkit::Refused => e
        "Error: #{e.message}"
      end

      # Before a wait on a child this call started or woke: its worker
      # takes the owner lock only once it has booted, so the wait's one
      # dead-worker rule (ReplyWait::GONE_AFTER) runs from there. A child a
      # worker (or a one-turn run) owns already goes straight on; else its
      # worker gets WorkerLink::START_LIMIT, the boot limit, to come up,
      # within the call's +timeout+ (its time counts against it) and
      # until the parent's turn is canceled.
      # @param cancelled [#call] the parent's cancel (Peers#cancelled?)
      # @return [Symbol] :up (a worker owns it), :gone (none came up within
      #   the boot limit), :timeout (+timeout+ ran out first) or :canceled
      def self.await_worker(child_id, state_dir:, timeout:, cancelled: -> { false })
        dir = Session.session_dir(child_id, state_dir: state_dir)
        return :up if WorkerPresence.read(child_id, state_dir: state_dir).owned?

        limit = [WorkerLink::START_LIMIT, timeout.to_f].min
        link = WorkerLink.await(child_id, session_dir: dir, timeout: limit, unlink: false,
                                          give_up: ->(found) { found.worker_owned? || cancelled.call })
        return :up if link&.worker_owned?
        return :canceled if cancelled.call

        limit < WorkerLink::START_LIMIT ? :timeout : :gone
      end

      def self.monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      private_class_method :monotonic

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

      # What to do when session.max_children are running: a parent that
      # gets reports ends its turn (a report frees a slot); one that
      # doesn't (DelegateWait.reports_mode off) waits with delegate_result.
      def self.full_hint(peers)
        if DelegateWait.reports_mode(peers) == "off"
          "delegate_result waits for one; `chi sessions stop ID` stops one."
        else
          "End your turn: a delegate report frees a slot when a child finishes; or stop one with `chi sessions stop ID`."
        end
      end
      private_class_method :full_hint

      # @param toolkit [String] a kit's name, "" for config's toolkit.child
      # @return [String, Array<String>] the new child's id, or an Error: line,
      #   and its warnings (each without the "Warning: " prefix)
      def self.start_child(task, parent:, model:, cwd:, toolkit:, state_dir:, peers:)
        if parent.parent_id
          return "Error: this session is a delegate of #{parent.parent_id}; delegated sessions don't delegate further"
        end

        folder = child_cwd(cwd, parent)
        return folder if folder.start_with?("Error:")

        unknown = unknown_toolkit(toolkit, peers)
        return unknown if unknown

        running = running_children(parent.id, state_dir: state_dir)
        max = max_children
        if running.size >= max
          ids = running.map(&:short_id).join(", ")
          return "Error: #{running.size} delegate#{"s" if running.size != 1} of this session #{running.size == 1 ? "is" : "are"} running " \
                 "(the most is #{max}, #{MAX_CHILDREN_KEY}): #{ids}. #{full_hint(peers)}"
        end

        # The parent's own parent_answers, as it is now (a snapshot): the
        # child's answers are held at least as tight.
        setup = SessionSetup.new(preloaded_memory_names: CHILD_MEMORIES,
                                 toolkit: toolkit.empty? ? nil : Toolkit.new(name: toolkit),
                                 parent_answers: parent.parent_answers)
        child = SessionManager.spawn_session(prompt: task, working_directory: folder,
                                             model_name: child_model(model, parent),
                                             parent_id: parent.id, delegate: true, setup: setup, state_dir: state_dir,
                                             client_id: ClientId.delegate(parent.id))
        DelegateWait.mark_started(parent.id, child, state_dir: state_dir)
        # The line for a task that names a worktree while the child runs in
        # the parent's folder (no cwd: given): the child still starts.
        [child.id, [child.model_warning, other_checkout(task, folder, parent: parent, child_id: child.id,
                                                        no_cwd: cwd.empty?)].compact]
      end
      private_class_method :start_child

      # A new child with no cwd: its task may name another checkout of this
      # repository (a worktree the parent meant to pass as cwd:), which makes
      # every write there an ask for the user (child-boundary). One warning
      # line, however many are named; nil when the task names none, or names
      # only the checkout holding the child's folder (or a subfolder of it),
      # or main while the child itself runs in a worktree of it.
      # Never raises: a started child must not come back as an Error:.
      # @return [String, nil]
      def self.other_checkout(task, folder, parent:, child_id:, no_cwd:)
        return nil unless no_cwd

        checkout = foreign_checkout(task, folder)
        return nil unless checkout

        Log.info(:worker, "delegate_other_checkout", parent: parent.id[0, 8])
        "this child runs in #{folder}, but its task names #{checkout}. If it should work there, stop it " \
          "(chi sessions stop #{child_id}) and call delegate again without session, with cwd: #{checkout}."
      rescue StandardError
        nil
      end
      private_class_method :other_checkout

      # The checkout of +folder+'s repository that the task names and that is
      # not the one holding +folder+: the first path token in the task that
      # belongs to one (the deepest containing it), else nil. Reads files
      # only, no git process, so a spec stubbing Process.spawn is unaffected.
      # A child started in a linked worktree is never pointed at main: its
      # work belongs in the worktree, so naming a main-checkout file - mostly
      # to read it - is not a cwd: the parent forgot.
      # @return [String, nil] an absolute checkout folder
      def self.foreign_checkout(task, folder)
        common = MemoryPaths.common_git_dir(folder)
        return nil unless common

        checkouts = Guardrails::GitInfo.checkouts(common).map { |checkout| File.realpath(checkout) }
        own = deepest_checkout(File.realpath(folder), checkouts)
        main = main_checkout(common)
        task.to_s.scan(PATH_TOKEN) do |token|
          path = existing_ancestor(File.expand_path(token.sub(/[.:!?]+\z/, ""), folder))
          next if path.nil?

          found = deepest_checkout(path, checkouts)
          next if found.nil? || found == own || found == main

          return found
        end
        nil
      end
      private_class_method :foreign_checkout

      # The main checkout of a common git dir (the folder holding it), nil for
      # a bare or separate-git-dir layout, which has none.
      def self.main_checkout(common)
        return nil unless File.basename(common) == ".git"

        File.realpath(File.dirname(common))
      rescue StandardError
        nil
      end
      private_class_method :main_checkout

      # The checkout containing +path+, matched by whole components (so
      # /x/app is not found in /x/app-fix): the deepest, so a nested worktree's
      # path belongs to that worktree, not to main; nil when none does.
      def self.deepest_checkout(path, checkouts)
        checkouts.select { |checkout| within?(path, checkout) }.max_by { |checkout| checkout.count("/") }
      end
      private_class_method :deepest_checkout

      # +path+'s longest ancestor that exists, realpathed (a worktree not made
      # yet still points at its parent folder); nil when nothing above it does.
      def self.existing_ancestor(path)
        dir = path
        until File.exist?(dir)
          parent = File.dirname(dir)
          return nil if parent == dir

          dir = parent
        end
        File.realpath(dir)
      rescue StandardError
        nil
      end
      private_class_method :existing_ancestor

      # The Error: line for a toolkit name the parent doesn't know
      # (Peers#toolkit_names: its built-in, config and plugin kits), nil
      # when it knows it, none was given, or the peers can't tell (a bare
      # kernel: the child's worker resolves it, full when it can't).
      def self.unknown_toolkit(toolkit, peers)
        return nil if toolkit.empty? || !peers.respond_to?(:toolkit_names)

        names = peers.toolkit_names
        return nil if names.nil? || names.include?(toolkit)

        "Error: no toolkit named #{toolkit} (toolkits: #{names.join(", ")})"
      end
      private_class_method :unknown_toolkit

      # The new child's folder: the parent's, or +cwd+ (relative to the
      # parent's) when it is a folder of the parent's project: in any of its
      # repository's worktrees (one project_root, from the common git dir), or
      # in its marked folder. Outside both only a subfolder of the parent's
      # folder. Nothing is created
      # here: the model makes a worktree with execute, where guardrails see it.
      # @return [String] an absolute folder, or an Error: line
      def self.child_cwd(cwd, parent)
        base = parent.working_directory
        return base if cwd.empty?

        folder = File.expand_path(cwd, base)
        return "Error: cwd #{folder} is not a folder (create the worktree first)" unless File.directory?(folder)

        folder = File.realpath(folder)
        unless same_project?(folder, base)
          return "Error: cwd must be a folder of this session's project (a worktree or subfolder of it), not #{folder}"
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

        out = IO.popen(GitEnv::UNSET, ["git", "-C", folder, "rev-parse", "--is-inside-work-tree"], err: File::NULL, &:read)
        out.strip == "true"
      rescue SystemCallError
        false
      end
      private_class_method :work_tree?

      def self.within?(path, dir) = path == dir || path.start_with?("#{dir}/")
      private_class_method :within?

      # One project (a git repository or a marked folder): the same project
      # root, so a nested repository or marked project is another one. A base
      # in no project: a subfolder of it.
      def self.same_project?(folder, base)
        if MemoryPaths.in_project?(base)
          MemoryPaths.project_root(folder) == MemoryPaths.project_root(base)
        else
          within?(folder, File.realpath(base))
        end
      rescue SystemCallError
        false
      end
      private_class_method :same_project?

      # @return [String] the child's id, or an Error: line
      def self.follow_up(task, session:, parent:, state_dir:)
        id = Session.resolve!(session, state_dir: state_dir)
        child = begin
          Session.load(id, state_dir: state_dir)
        rescue Session::NotFound
          raise # gone since resolve!: the outer rescue adds the list_sessions hint
        rescue ArgumentError => e # a file that won't load
          return "Error: #{e.message}"
        end
        unless child.parent_id == parent.id
          return "Error: #{id[0, 8]} is not a delegate of this session; send_note reaches any session"
        end

        # Only a reply after this delivery counts as the follow-up's.
        DelegateWait.mark_seen(parent.id, child, state_dir: state_dir)
        delivered = SessionManager.deliver_turn(id, prompt: task, client_id: ClientId.delegate(parent.id),
                                                    state_dir: state_dir)
        case delivered.status
        when :accepted
          DelegateWait.mark_turn(parent.id, id, follow_up_turn(id, delivered.enqueued_id, state_dir: state_dir), state_dir: state_dir)
          id
        when :refused then "Error: session #{id[0, 8]} #{delivered.refusal_text}"
        when :timeout then "Error: the worker of session #{id[0, 8]} did not answer in time, so the message was not sent"
        else "Error: the message to session #{id[0, 8]} could not be written"
        end
      rescue SessionManager::ScratchSession => e
        "Error: session #{id[0, 8]}: #{e.message}"
      rescue SessionManager::OwnedByTUI
        "Error: session #{id[0, 8]} is #{OwnerLock::TUI_BUSY}, which can't take a delegated message"
      rescue Session::NotFound => e
        "Error: #{e.message} (list_sessions shows them)"
      rescue Session::AmbiguousId => e
        "Error: #{e.message}"
      end
      private_class_method :follow_up

      # The child's turn a delivered follow-up's wait is bound to
      # (DelegateCursor#turn): its own, the delivery's +enqueued_id+,
      # whether it runs as a turn of its own (the child idle, or its
      # running turn ended before taking it) or a running turn's drain
      # merges it (that turn's end is its answer: the drain's merge record,
      # or ReplyWait's inference for a 0.156 child, ReplyWait::Poll#
      # follow_merge). Only from a worker that names turn_ids; nil
      # otherwise: the wait takes the next reply.
      # @return [String, nil]
      def self.follow_up_turn(id, enqueued_id, state_dir:)
        ReplyWait.turn_ids?(Session.session_dir(id, state_dir: state_dir)) ? enqueued_id : nil
      end
      private_class_method :follow_up_turn

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
      # A child spawned moments ago counts as running even before its worker
      # holds the owner lock (SessionRow#running_or_starting?): two delegate
      # calls in one model message come milliseconds apart, and the first
      # child's worker is still starting when the second call counts.
      # @return [Array<SessionRow>] SessionManager.children_of rows
      def self.running_children(parent_id, state_dir:)
        SessionManager.children_of(parent_id, state_dir: state_dir).select(&:running_or_starting?)
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
