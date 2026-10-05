# frozen_string_literal: true

require_relative "../session"
require_relative "../config"
require_relative "../model_profile"
require_relative "peers"
require_relative "delegate_wait"

module Samagotchi
  # Loaded on first use: session_manager requires terminal_ui, which
  # requires KernelLoop and so these tools (a require cycle otherwise).
  autoload :SessionManager, File.expand_path("../session_manager", __dir__)

  module Tools
    # Hand a task to a child session: an ordinary chi session in its own
    # worker, started in this session's folder with the task as its first
    # user message and the `delegated` system memory preloaded. It shows in
    # every list as a child of this one and the user can attach to it. With
    # session:, a follow-up to a child that exists. Only the child's final
    # reply comes back (DelegateWait), never its trace.
    class Delegate
      NAME = "delegate"
      CLIENT_PREFIX = "delegate"
      MAX_CHILDREN_KEY = "session.max_children"
      MAX_CHILDREN_DEFAULT = 4
      # A child spawned this many seconds ago counts as running even before
      # its worker holds the owner lock: two delegate calls in one model
      # message come milliseconds apart, and the first child's worker is
      # still starting when the second call counts.
      STARTING_GRACE_SECONDS = 15
      # The memory every child starts with, scoped so a project memory of
      # the same name cannot shadow it.
      CHILD_MEMORIES = ["system/delegated"].freeze

      def self.name = NAME

      # @param content [String] the task (the child's user message, verbatim)
      # @param model [String, nil] the child's model (an alias works); the parent's by default
      # @param session [String, nil] a child's id or prefix: send the task there instead
      # @param wait [Boolean, String, nil] wait for the reply (default true)
      # @param timeout [Integer, String, nil] seconds to wait (default DelegateWait::TIMEOUT_DEFAULT)
      # @param peers [Peers, nil]
      def self.call(content, model: nil, session: nil, wait: nil, timeout: nil, peers: nil)
        return "Error: this session's id is not known here" unless peers&.session_id

        task = content.to_s.strip
        return "Error: give the task, the child's first message" if task.empty?

        sd = peers.state_dir || Session.default_state_dir
        parent = Session.load(peers.session_id, state_dir: sd)
        wait = parse_wait(wait)
        timeout = parse_timeout(timeout)

        child_id, warning = if session.to_s.strip.empty?
                              start_child(task, parent: parent, model: model, state_dir: sd)
                            else
                              follow_up(task, session: session.to_s.strip, parent: parent, state_dir: sd)
                            end
        return child_id if child_id.start_with?("Error:")

        note = warning ? "Warning: #{warning}\n" : ""
        return note + DelegateWait.call(child_id, peers: peers, timeout: timeout) if wait

        started = session.to_s.strip.empty? ? "Started a delegate session" : "Sent the follow-up to delegate #{child_id[0, 8]}"
        "#{note}session: #{child_id}\nstatus: running\n#{started}; delegate_result waits for its reply. " \
          "It shows in chi sessions list and the web as a child of this session; the user can attach to it."
      rescue ArgumentError => e
        "Error: #{e.message}"
      end

      # @return [String] the new child's id, or an Error: line
      def self.start_child(task, parent:, model:, state_dir:)
        if parent.parent_id
          return "Error: this session is a delegate of #{parent.parent_id}; delegated sessions don't delegate further"
        end

        running = running_children(parent.id, state_dir: state_dir)
        max = max_children
        if running.size >= max
          ids = running.map { |s| s[:short_id] }.join(", ")
          return "Error: #{running.size} delegate#{"s" if running.size != 1} of this session #{running.size == 1 ? "is" : "are"} running " \
                 "(the most is #{max}, #{MAX_CHILDREN_KEY}): #{ids}. delegate_result waits for one; `chi sessions stop ID` stops one."
        end

        child = SessionManager.spawn_session(prompt: task, working_directory: parent.working_directory,
                                             model_name: child_model(model, parent), memories: CHILD_MEMORIES,
                                             parent_id: parent.id, state_dir: state_dir)
        DelegateWait.mark_started(parent.id, child)
        [child.id, child.model_warning]
      end
      private_class_method :start_child

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
        delivered = SessionManager.deliver_turn(id, prompt: task, client_id: "#{CLIENT_PREFIX}:#{parent.id[0, 8]}",
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

      # busy (a worker runs its turn), or running with a worker on its way.
      def self.running?(summary)
        return true if summary[:busy]
        return false unless summary[:status] == Session::STATUS_RUNNING && !summary[:live]

        Time.now - Time.iso8601(summary[:updated_at].to_s) < STARTING_GRACE_SECONDS
      rescue ArgumentError
        false
      end
      private_class_method :running?

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
