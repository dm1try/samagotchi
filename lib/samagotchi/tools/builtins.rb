# frozen_string_literal: true

require_relative "registry"
require_relative "../tool_declarations"
require_relative "execute"
require_relative "read"
require_relative "write"
require_relative "memory"
require_relative "edit"
require_relative "task_create"
require_relative "task_get"
require_relative "task_list"
require_relative "task_stop"
require_relative "task_wait"
require_relative "web_fetch"
require_relative "register_reminder"
require_relative "cancel_reminder"
require_relative "list_reminders"
require_relative "list_sessions"
require_relative "send_note"
require_relative "delegate"
require_relative "delegate_result"
require_relative "ask_user_question"

module Samagotchi
  module Tools
    # chi's own tools as Registry entries: each schema from
    # ToolDeclarations::TOOL_SCHEMAS, with a handler (call, kctx) that runs
    # its class. kctx (KernelLoop::ToolContext) gives what some need from the
    # kernel: the reminder store, the peers, the model key, the muted memory
    # read and the ask-user flow.
    module Builtins
      CLASSES = [
        Execute,
        Read,
        Write,
        MemoryRead,
        MemoryWrite,
        Edit,
        TaskCreate,
        TaskGet,
        TaskList,
        TaskStop,
        TaskWait,
        WebFetch,
        RegisterReminder,
        CancelReminder,
        ListReminders,
        ListSessions,
        SendNote,
        Delegate,
        DelegateResult,
        AskUserQuestion
      ].freeze

      # The handlers that pass more than the call's content.
      HANDLERS = {
        MemoryRead::NAME => ->(call, kctx) { kctx.muted_memory_read(call) },
        MemoryWrite::NAME => lambda do |call, kctx|
          MemoryWrite.call(call[:content], path: call[:path], scope: call[:scope], description: call[:description],
                                           current_model_only: truthy?(call[:current_model_only]),
                                           model_key: kctx.model_key)
        end,
        Write::NAME => ->(call, _kctx) { Write.call(call[:content], path: call[:path]) },
        Read::NAME => lambda do |call, _kctx|
          Read.call(call[:content], start_line: call[:start_line], end_line: call[:end_line])
        end,
        Edit::NAME => lambda do |call, _kctx|
          Edit.call(call[:content], path: call[:path], start_line: call[:start_line], end_line: call[:end_line])
        end,
        TaskCreate::NAME => lambda do |call, kctx|
          next Execute::NOT_RUN_ON_STOP if cancelled_proc(kctx).call

          TaskCreate.call(call[:content], cwd: call[:cwd], env: call[:env])
        end,
        TaskWait::NAME => lambda do |call, kctx|
          TaskWait.call(call[:content], timeout: call[:timeout], tail_lines: call[:tail_lines],
                                        done_pattern: call[:done_pattern], cancelled: cancelled_proc(kctx))
        end,
        Execute::NAME => ->(call, kctx) { Execute.call(call[:content], cwd: call[:cwd], cancelled: cancelled_proc(kctx)) },
        RegisterReminder::NAME => lambda do |call, kctx|
          RegisterReminder.call(call[:content], reminder_store: kctx.reminder_store, description: call[:description],
                                                interval_minutes: call[:interval_minutes])
        end,
        CancelReminder::NAME => ->(call, kctx) { CancelReminder.call(call[:content], reminder_store: kctx.reminder_store) },
        ListReminders::NAME => ->(call, kctx) { ListReminders.call(call[:content], reminder_store: kctx.reminder_store) },
        ListSessions::NAME => ->(call, kctx) { ListSessions.call(call[:content], peers: kctx.peers, cwd: call[:cwd]) },
        SendNote::NAME => ->(call, kctx) { SendNote.call(call[:content], session: call[:session], peers: kctx.peers) },
        Delegate::NAME => lambda do |call, kctx|
          Delegate.call(call[:content], model: call[:model], session: call[:session], wait: call[:wait],
                                        timeout: call[:timeout], peers: kctx.peers)
        end,
        DelegateResult::NAME => lambda do |call, kctx|
          DelegateResult.call(call[:content], session: call[:session], timeout: call[:timeout], peers: kctx.peers)
        end,
        AskUserQuestion::NAME => ->(call, kctx) { kctx.ask_user_question(call) }
      }.freeze

      module_function

      # Stop flips the turn's controller, seen through the Engine's PeerView
      # (as DelegateWait does); a bare kernel has no peers: never cancelled.
      def cancelled_proc(kctx)
        peers = kctx.peers
        -> { peers.respond_to?(:cancelled?) && peers.cancelled? }
      end

      # @return [Registry] a new registry with the built-ins, in
      #   TOOL_SCHEMAS order (an Engine's own, which bundles add to)
      def registry
        by_name = CLASSES.to_h { |klass| [klass::NAME, klass] }
        ToolDeclarations::TOOL_SCHEMAS.each_with_object(Registry.new) do |schema, registry|
          klass = by_name.fetch(schema[:name])
          handler = HANDLERS.fetch(klass::NAME) { ->(call, _kctx) { klass.call(call[:content]) } }
          registry.register(klass::NAME, schema: schema, handler: handler)
        end
      end

      # @return [Registry] the built-ins alone, frozen: a KernelLoop or a
      #   ChatLoop without an Engine's registry uses it
      def default
        @default ||= registry.freeze
      end

      def truthy?(val)
        return true if val == true
        return false if val == false || val.nil?

        val.to_s.strip.downcase == "true"
      end
    end
  end
end
