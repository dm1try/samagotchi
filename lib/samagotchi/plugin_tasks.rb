# frozen_string_literal: true

require_relative "cancellation_controller"
require_relative "log"
require_relative "plugin/api"

module Samagotchi
  # An Engine's plugin init tasks (chi.init) and the tool sets plugins stage
  # (chi.replace_tools) for the turn thread.
  #
  # A plugin's slow setup (docs/plugins.md, Init tasks): run on its own
  # thread once the owner can show it (#start!), announced as
  # plugin_init_started / plugin_init_finished unless quiet. A turn waits
  # for the running ones that provide tools before its first model request
  # (#await), up to each one's timeout.
  #
  # What it needs from the Engine comes through lookups, called at use.
  # Lock order: the Engine's lifecycle lock may be held when this one is
  # taken (#shut_down!), the event lock too (#running); this lock is never
  # held while the event lock is taken.
  class PluginTasks
    # +cancel+ is the task's own controller, cancelled only by #shut_down!:
    # a Ctrl-C ends a turn's wait, not the task.
    InitTask = Struct.new(:id, :bundle, :label, :plugin_label, :provides_tools, :quiet, :timeout, :failed, :block,
                          :cancel, :thread, :state, :started_at, keyword_init: true) do
      # What the task's block reads: whether chi is shutting down.
      def cancelled? = cancel.cancelled?
    end

    # How long a task may hold a turn when it gives no timeout.
    INIT_TASK_TIMEOUT = 60.0

    INIT_WAIT_POLL = 0.05

    # @param clock              [#call] → Float, monotonic seconds
    # @param synchronize_events [#call] (&block) → runs the block holding the event log
    # @param announce           [#call] (event) → announces an event
    # @param emit               [#call] (sink, event) → emits to a turn's sink + observers
    # @param show_card          [#call] (**card) → shows a card
    # @param tools              [#call] → Tools::Registry
    # @param notify             [#call] (text, level, source) → a notice
    # @param tools_changed      [#call] → the tools changed (prompts built again)
    def initialize(clock:, synchronize_events:, announce:, emit:, show_card:, tools:, notify:, tools_changed:)
      @clock = clock
      @synchronize_events = synchronize_events
      @announce = announce
      @emit = emit
      @show_card = show_card
      @tools = tools
      @notify = notify
      @tools_changed = tools_changed
      @mutex = Mutex.new
      @shut_down = false
      @tasks = []
      # Plugins' tool sets from chi.replace_tools, by bundle, until the
      # turn thread applies them (#apply_staged_tools!).
      @staged_tools = {}
    end

    # Add a plugin's init task (Plugin::Api#init at commit); it starts with
    # #start!.
    def add(bundle:, label:, plugin_label:, provides_tools:, quiet:, timeout:, failed: nil, &block)
      @mutex.synchronize do
        @tasks << InitTask.new(id: "#{bundle}-#{@tasks.size + 1}", bundle: bundle.to_s, label: label.to_s,
                               plugin_label: plugin_label, provides_tools: provides_tools ? true : false,
                               quiet: quiet ? true : false, timeout: timeout || INIT_TASK_TIMEOUT, failed: failed,
                               block: block, cancel: CancellationController.new, state: :pending)
      end
      nil
    end

    # Start the init tasks not started yet, each on its own thread. The
    # worker calls it once its Bridge is up, the REPL once it renders
    # events, and every turn (a -p run has only that); later calls start
    # nothing new.
    def start!
      @mutex.synchronize do
        return if @shut_down

        @tasks.each do |task|
          next unless task.state == :pending

          task.state = :starting
          task.started_at = @clock.call
          task.thread = Thread.new { run(task) }
          task.thread.report_on_exception = false
        end
      end
      nil
    end

    # The running init tasks a UI shows (not the quiet ones), for a UI that
    # joins while they run (Bridge#snapshot, with the event log held).
    # @return [Array<Hash>] {bundle:, id:, label:}
    def running
      @mutex.synchronize do
        @tasks.select { |task| task.state == :running && !task.quiet }
              .map { |task| { bundle: task.bundle, id: task.id, label: task.label } }
      end
    end

    # Wait for the running init tasks that provide tools, each up to its
    # timeout from its start, while +controller+ isn't cancelled; tell the
    # turn's sink what it waits for (:plugin_init_wait). A task that ends
    # late or fails leaves the turn without its tools.
    # @return [Boolean] whether it waited
    def await(controller = nil, on_event = nil)
      waiting = @mutex.synchronize do
        @tasks.select { |task| task.provides_tools && %i[starting running].include?(task.state) }
      end
      return false if waiting.empty?

      @emit.call(on_event, { type: :plugin_init_wait,
                             tasks: waiting.map { |task| { bundle: task.bundle, id: task.id, label: task.label } } })
      started = @clock.call
      loop do
        now = @clock.call
        left = waiting.select { |task| %i[starting running].include?(task.state) && now < task.started_at + task.timeout }
        break if left.empty? || controller&.cancelled?

        sleep(INIT_WAIT_POLL)
      end
      Log.info(:plugins, "init_wait", ms: ((@clock.call - started) * 1000).round,
                                      cancelled: controller&.cancelled? || nil)
      true
    end

    # The init task this thread runs, or nil.
    def current = Thread.current[:"samagotchi_init_#{object_id}"]

    # Keep a plugin's new tool set (chi.replace_tools, from any thread)
    # for the turn thread, which applies it (#apply_staged_tools!): the
    # registry is read only there. A later set of the same bundle wins.
    def stage_tools(bundle, specs, context)
      @mutex.synchronize do
        return if @shut_down

        @staged_tools[bundle] = [specs, context]
      end
      nil
    end

    # Apply the staged tool sets (#stage_tools), on the turn thread, before
    # the turn's system prompt is built; the prompts are built again when
    # a set changed anything. A name another source has is left out with a
    # notice.
    # @return [Boolean] whether the tools changed
    def apply_staged_tools!
      staged = @mutex.synchronize do
        taken = @staged_tools
        @staged_tools = {}
        taken
      end
      changed = false
      staged.each do |bundle, (specs, context)|
        result = Plugin::Api.apply_tools(@tools.call, bundle, specs, context)
        changed ||= result[:changed]
        result[:skipped].each do |why|
          Log.warn(:plugins, "plugin_tool_skipped", bundle: bundle, msg: why)
          @notify.call("#{why}; left out", :warn, bundle)
        end
        Log.info(:plugins, "plugin_tools_replaced", bundle: bundle, tools: specs.size) if result[:changed]
      end
      @tools_changed.call if changed
      changed
    end

    # Shutting down (Engine#shutdown, under its lifecycle lock): nothing
    # starts or stages after this; an init task's requests end (a server's
    # boot), so it finishes.
    # @return [Array<Thread>] the task threads, to join
    def shut_down!
      @mutex.synchronize do
        @shut_down = true
        @tasks.each { |task| task.cancel.cancel!(:shutdown) }
        @tasks.filter_map(&:thread)
      end
    end

    # After the joins: the task threads still alive are killed.
    def kill_leftovers
      @tasks.each { |task| task.thread&.kill if task.thread&.alive? }
    end

    # @return [Array<InitTask>] a copy of the task list (specs)
    def tasks
      @mutex.synchronize { @tasks.dup }
    end

    private

    def run(task)
      Thread.current[:"samagotchi_init_#{object_id}"] = task
      @synchronize_events.call do
        task.state = :running
        @announce.call({ type: :plugin_init_started, bundle: task.bundle, id: task.id, label: task.label }) unless task.quiet
      end
      Log.info(:plugins, "init_started", bundle: task.bundle, id: task.id, label: task.label)
      summary = task.block.call(task)
      finish(task, ok: true, summary: summary.is_a?(String) ? summary : nil)
    rescue StandardError => e
      finish(task, ok: false, error: e.message)
    end

    def finish(task, ok:, summary: nil, error: nil)
      Log.public_send(ok ? :info : :warn, :plugins, "init_finished", bundle: task.bundle, id: task.id, ok: ok,
                                                                      ms: ((@clock.call - task.started_at) * 1000).round,
                                                                      msg: error)
      shut_down = @mutex.synchronize { @shut_down }
      @synchronize_events.call do
        task.state = ok ? :done : :failed
        next if shut_down || (task.quiet && ok)

        unless task.quiet
          @announce.call({ type: :plugin_init_finished, bundle: task.bundle, id: task.id, label: task.label, ok: ok,
                           summary: summary, error: error }.compact)
        end
        # A failure stays on screen (and for a UI that joins later) as a
        # card: a short title (the card shows the bundle beside it), the
        # detail in the body.
        unless ok
          title = task.failed || "setup failed"
          body = task.failed ? error.to_s : "#{task.label}: #{error}"
          @show_card.call(source: task.bundle, title: title, body: body, level: :warn, id: "init-#{task.id}")
        end
      end
    end
  end
end
