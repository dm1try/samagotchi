# frozen_string_literal: true

require_relative "tool_activity"
require_relative "tool_row_fields"
require_relative "row_refs"
require_relative "file_ref"
require_relative "guardrails"
require_relative "vision_context"
require_relative "degrade"
require_relative "stream_event"
require_relative "log"
require_relative "edit_preview"
require_relative "tool_output_cut"
require_relative "tool_output_files"
require_relative "tools/output_guardrails"
require_relative "tools/tool_path"
require_relative "tools/tool_surface"
require_relative "tools/memory"
require_relative "config"
require_relative "memory_bundle/index_sync"
require_relative "memory_bundle/index_size"
require_relative "memory_bundle/entry_size"
require_relative "participant_mode"

module Samagotchi
  # One call's result from ToolRunner#run, read by ToolResponse (the loops'
  # tool_response entries) and the loops' activity list. Fields a call didn't
  # produce (images, shown_params, shown_label, refs, diff, output_file,
  # loaded, stamp) are nil. +loaded+: the tools a find_tools hit loads
  # (Tools::ToolIndex::FoundText#loaded), by their wire names. +stamp+: an
  # ok read/edit/write's file right after it ran ({path:, mtime_ns:,
  # size:}), what WorkingSet tells a file changed since by.
  ToolRun = Data.define(:output, :capped_output, :truncated, :activity, :images, :shown_params, :shown_label, :refs, :diff,
                        :output_file, :loaded, :stamp) do
    def initialize(output: nil, capped_output: nil, truncated: nil, activity: nil, images: nil, shown_params: nil,
                   shown_label: nil, refs: nil, diff: nil, output_file: nil, loaded: nil, stamp: nil)
      super
    end
  end

  # The single per-call path both loops use: the tool_call_started and
  # tool_call_completed events, the guardrail gate (before_tool_call hooks
  # and their veto), dispatch through KernelLoop, the after_tool_call hook
  # and the output cap. Both loops feed the model `capped_output:` (cut to
  # the cap by the tool's ToolOutputCut policy, with a "[cut: …]" line),
  # the text the event and the hook get too. memory_read has its own cap,
  # memory.read_max_chars (0: none), not max_tool_output_chars.
  class ToolRunner
    # More images in one result are left out, each with a line (a tool
    # that returns many screenshots can't flood the context).
    MAX_IMAGES_PER_RESULT = 4

    # file_before for a call that isn't an edit/write, or won't run.
    NOT_AN_EDIT = Object.new.freeze
    private_constant :NOT_AN_EDIT

    # What a call needs of its turn comes with it: #run's +context:+ (a
    # TurnContext: the session's folders, the settings' vision, its
    # ToolSurface, the participant's mode), passed on to the gate and the
    # kernel's dispatch.
    #
    # @param kernel [KernelLoop] its services (KernelLoop::Services: hooks,
    #   tools, gate) are read per call: a spec's kernel may #attach new ones.
    # @param clock [#call] monotonic seconds, for the approval wait and the
    #   dispatch time (after_tool_call's elapsed_ms)
    # @param window [#call, nil] (settings) → ContextWindow::Resolved or nil:
    #   the model's window under the turn's LLM::TurnSettings, for
    #   memory_read's overflow guard. nil: the kernel's own reader
    #   (KernelLoop#tool_output_window); a loop whose window comes from more
    #   than the kernel's client (LLM::ChatLoop's adapter) passes it.
    def initialize(kernel, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, window: nil)
      @kernel = kernel
      @clock = clock
      @window = window
    end

    # @param call_index [Integer] 1-based position of the call in its batch
    # @return [ToolRun] output:, capped_output:, truncated:, activity:,
    #   output_file: (the saved whole output of a cut execute result),
    #   images: (refs) when the tool returned images the model gets to see, and
    #   shown_params: the params line the live row showed, and shown_label:
    #   its label ("chrome: screenshot"), only for a tool that isn't built in
    #   (the loops save them with the result, so a reload without the plugin
    #   shows the same row), refs: its row's refs (a plugin tool's refs:,
    #   RowRefs; saved likewise), and diff: what an edit/write changed in its
    #   file (EditPreview.change; also on tool_call_completed, never in the
    #   model's output)
    # @param context [TurnContext] the call's turn
    def run(call, context:, iteration:, call_index:, call_count:, on_stream_event:, max_tool_output_chars:)
      # A call_tool of one of chi's own tools runs as that tool, from here
      # on (the gate, the row, the result): rules, approvals and hooks see
      # the real call, with via: (Tools::ToolIndex#unwrap).
      call = unwrapped(call, context)
      params = ToolActivity.tool_activity_params(call[:name], call, registry: tools)
      # The gate runs first, so tool_call_started shows the call that runs.
      # A tool the session's toolkit leaves out skips it: no before_tool_call
      # hook, no approval card for a call that can't run (KernelLoop#dispatch
      # answers it with the not-loaded error).
      original = call.dup
      refusal = unreached_group_refusal(call, context)
      verdict = if refusal
                  Guardrails::Verdict.new(call: call).deny!(refusal.message,
                                                            rule: Tools::ToolIndex::ToolkitGroupRefusal::RULE,
                                                            source: "core", decided_by: "core")
                elsif left_out?(call, context)
                  Guardrails::Verdict.new(call: call)
                else
                  evaluate(call, context, iteration, params)
                end
      call = verdict.call
      params = ToolActivity.tool_activity_params(call[:name], call, registry: tools)
      label = plugin_label(call[:name])
      # Kept on the raw event for in-worker hooks and metrics, not sent to SSE clients.
      started = { type: :tool_call_started, iteration: iteration, call_count: call_count, call_index: call_index,
                  tool: call[:name], call: call.dup, params: params }
      started[:label] = label if label
      # Its row fields (ToolRowFields: title, called_as, via, view, ref, and a
      # plugin tool's refs); the worker runs in its session's working
      # directory.
      fields = ToolRowFields.for(call[:name], call, cwd: Dir.pwd)
      refs = RowRefs.for(tools && !call[:name].nil? ? tools[call[:name]]&.refs : nil, call, cwd: session_cwd(context))
      fields[:refs] = refs unless refs.empty?
      started.merge!(fields)
      emit(on_stream_event, started)

      # The ask comes after tool_call_started: the UI shows the tool line,
      # then the approval under it. waited_ms on tool_call_completed lets a
      # UI that times the row from tool_call_started leave the wait out.
      waited_ms = nil
      if verdict.ask?
        asked_at = @clock.call
        settle_ask(verdict, context)
        waited_ms = ((@clock.call - asked_at) * 1000).round
      end
      before = verdict.deny? ? NOT_AN_EDIT : file_before(call)
      index_before = before.equal?(NOT_AN_EDIT) ? nil : memory_index_size(call)
      entry_before = before.equal?(NOT_AN_EDIT) ? nil : MemoryBundle::EntrySize.measure_file(Tools::ToolPath.normalize(call[:path]))
      elapsed_ms = nil
      if verdict.deny?
        result = denied(call, verdict)
      else
        dispatched_at = @clock.call
        result = dispatch(call, context)
        elapsed_ms = ((@clock.call - dispatched_at) * 1000).round
      end
      diff = file_change(call, before)
      if diff && refresh_memory_index(call)
        result = with_index_note(result, index_before, call)
        result = with_entry_note(result, entry_before, call)
      end
      result = approved(result, verdict) if verdict.allow? && verdict.decided_by
      result, images = attach_images(call, result, context.settings&.vision) if result[:images]

      output = scrub(result[:output].to_s)
      # The tool's own text, for after_tool_call: no "[tool]" lead, no
      # ran-as line, no cap.
      tool_text = output.sub(/\A\[#{Regexp.escape(call[:name].to_s)}\](?:\n| )/, "")
      # The gate may have replaced the call (known-names corrects a near
      # miss): one leading line tells the model what actually ran.
      if (changed = changed_call_line(original, call))
        output = "#{changed}\n#{output}"
      end
      cap = output_cap(call, max_tool_output_chars, context)
      truncated = !cap.nil? && output.length > cap
      capped, saved = truncated ? cut(call, output, cap, result, context) : output
      output_file = saved.path if saved.is_a?(ToolOutputFiles::Saved)

      # The call's outcome as its activity line has it (worked out from the
      # full output: ok, error, blocked, stopped); a dispatcher that raised
      # left none, an error.
      status = result[:activity].is_a?(Hash) ? result[:activity][:status] : nil
      completed = { type: :tool_call_completed, iteration: iteration, call_count: call_count, call_index: call_index,
                    tool: call[:name], output: capped, output_truncated: truncated, activity: result[:activity] }
      completed[:images] = images if images&.any?
      completed[:diff] = diff if diff
      completed[:waited_ms] = waited_ms if waited_ms
      completed[:output_file] = output_file if output_file
      # Also here: a UI that missed the start (a replay gap) builds its row
      # from this event (its title is in the activity).
      completed.merge!(fields.slice(*ToolRowFields::EVENT_KEYS))
      emit(on_stream_event, completed)
      # After the completed event: a hook's card (check-in, skills) prints
      # under the call's tool row, not before it.
      fire(:after_tool_call, { type: :after_tool_call, iteration: iteration, tool: call[:name], output: capped,
                               status: status || "error", call: call.dup, elapsed_ms: elapsed_ms, result: tool_text })

      ToolRun.new(output: output, capped_output: capped, truncated: truncated, activity: result[:activity],
                  images: images&.any? ? images : nil,
                  shown_params: params && plugin_tool?(call[:name]) ? params : nil,
                  shown_label: label, refs: refs.empty? ? nil : refs, diff: diff, output_file: output_file,
                  loaded: result[:loaded], stamp: status == "ok" ? file_stamp(call, context) : nil)
    end

    private

    # An ok read/edit/write's file as it is now, right after the call:
    # {path:, mtime_ns:, size:}, the path as FileRef has it (against the
    # session's folder, no realpath). nil for any other tool, a path it
    # can't place and a stat that fails or isn't a file's.
    def file_stamp(call, context)
      ref = FileRef.for(call[:name], call, cwd: session_cwd(context))
      return nil unless ref

      stat = File.stat(ref.path)
      return nil unless stat.file?

      { path: ref.path, mtime_ns: (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec, size: stat.size }
    rescue SystemCallError
      nil
    end

    # +output+ cut to +cap+ by its tool's policy (ToolOutputCut); an
    # execute result keeps its tail too, its whole output saved in the
    # session's folder.
    # @param result [Hash] the dispatch's: its ref_path is the file the
    #   whole text is in (a task's log, a child's reply: Tools::RefText),
    #   for task_wait and delegate; ref_stderr_path, a task's stderr log
    # @return [Array(String, Object)] the text, and the saved file (or why
    #   there is none) when it was cut that way
    def cut(call, output, cap, result, context)
      ToolOutputCut.apply(output, cap: cap, tool: call[:name],
                                  save: ->(text, dry: false) { save_output(call, text, context.session_dir, dry: dry) },
                                  line: (memory_cut_line(call) if call[:name] == MEMORY_READ),
                                  ref: result[:ref_path], ref_stderr: result[:ref_stderr_path],
                                  head_chars: Tools::OutputGuardrails.config_positive_int("execute.cut_head_chars",
                                                                                          ToolOutputCut::HEAD_CHARS))
    end

    MEMORY_READ = Tools::MemoryRead::NAME

    # The most chars +call+'s result may hold: +cap+ (max_tool_output_chars)
    # for every tool but memory_read, which memory.read_max_chars caps (0:
    # no fixed cap) and, with none set, a known window's half (#window_guard).
    # A nil +cap+ stays nil.
    def output_cap(call, cap, context)
      return cap unless cap && call[:name] == MEMORY_READ

      fixed = Config.get("memory.read_max_chars").to_i
      fixed.positive? ? fixed : window_guard(context.settings)
    end

    # Half the model's context window in characters, the most one memory_read
    # result may take: a context overflow fails the turn (its work rolls back
    # and a retry repeats the read). nil when the window isn't known (the
    # default isn't a window) or can't be read. It checks this result, not the
    # context already used.
    def window_guard(settings)
      Degrade.call(:memory, "read_window_unknown") do
        window = @window ? @window.call(settings) : (@kernel.tool_output_window(settings) if @kernel.respond_to?(:tool_output_window))
        return nil unless window&.tokens&.positive? && window.source != :default

        (window.tokens * MemoryBundle::IndexSize.chars_per_token / 2).floor
      end
    end

    # memory_read's cut line: the rest is in the memory's file, in the dir(s)
    # the call searched (a scope, else project then system).
    def memory_cut_line(call)
      scope = call[:scope].to_s.strip
      scopes = Tools::VALID_SCOPES.include?(scope) ? [scope] : Tools::VALID_SCOPES
      names = Tools::MemoryRead.parse_names(call[:content].to_s)
      ToolOutputCut.memory_line(scopes.map { |s| Tools::MemoryRead.memories_dir(s) }, single: names.size == 1)
    end

    # The whole output in the session's tool_output folder
    # (ToolOutputFiles; +dir+: the turn's TurnContext#session_dir), or why it
    # isn't saved: no session (a bare kernel) or the error's class. Never
    # fails the call. +dry+: where it would go, nothing written
    # (ToolOutputFiles.planned).
    # @return [ToolOutputFiles::Saved, String]
    def save_output(call, text, dir, dry: false)
      return "no session" if dir.to_s.empty?
      return ToolOutputFiles.planned(dir, text, tool: call[:name]) if dry

      ToolOutputFiles.save(dir, text, tool: call[:name])
    rescue SystemCallError => e
      Log.warn(:turn, "tool_output_save_failed", tool: call[:name], error: e.class.name)
      e.class.name
    end

    # edit/write only: the file just before the call runs. The row diffs it
    # with the file after, whatever the result says, so an edit that fails
    # after writing still shows its change and one that wrote nothing shows
    # none.
    def file_before(call)
      return NOT_AN_EDIT unless EditPreview.tool?(call[:name])

      EditPreview.snapshot(Tools::ToolPath.normalize(call[:path]))
    rescue StandardError
      NOT_AN_EDIT
    end

    def file_change(call, before)
      return nil if before.equal?(NOT_AN_EDIT)

      EditPreview.change(before, EditPreview.snapshot(Tools::ToolPath.normalize(call[:path])))
    rescue StandardError => e
      Log.warn(:turn, "edit_diff_failed", tool: call[:name], error: "#{e.class}: #{e.message}")
      nil
    end

    # A write/edit that changed a memory's file refreshes its index line,
    # as memory_write does (MemoryBundle::IndexSync; a no-op elsewhere).
    def refresh_memory_index(call)
      MemoryBundle::IndexSync.refresh(Tools::ToolPath.normalize(call[:path]))
    end

    # The index size of the memory scope an edit/write's path is in
    # (MemoryBundle::IndexSize), nil for any other path, or when
    # memory.index_warn_tokens is off: other writes cost nothing.
    def memory_index_size(call)
      Degrade.call(:memory, "index_size_unreadable") do
        scope = MemoryBundle::IndexSync.memory_scope(Tools::ToolPath.normalize(call[:path]))
        return nil unless scope && MemoryBundle::IndexSize.warn_limit.positive?

        MemoryBundle::IndexSize.measure(scope)
      end
    end

    # +result+ with the note memory_write gives when the refreshed index
    # line took the scope's index over memory.index_warn_tokens.
    def with_index_note(result, before, call)
      return result unless before

      note = MemoryBundle::IndexSize.crossing_note(before, memory_index_size(call))
      note ? result.merge(output: "#{result[:output]}\n\n#{note}") : result
    end

    # +result+ with the note a write/edit gets when it took the memory over
    # memory.entry_warn_tokens (MemoryBundle::EntrySize). It is apart from
    # the index's: that one is off with index_warn_tokens at 0, this one isn't.
    def with_entry_note(result, before, call)
      return result unless before

      note = MemoryBundle::EntrySize.crossing_note(before, MemoryBundle::EntrySize.measure_file(Tools::ToolPath.normalize(call[:path])))
      note ? result.merge(output: "#{result[:output]}\n\n#{note}") : result
    end

    # A tool's output can hold bytes that aren't UTF-8 (`printf '\xff'`, a
    # binary file). They become "?" here, before the output reaches the
    # conversation, the events and the saved session: JSON.generate raises
    # on them, and the session would fail to save.
    def scrub(text)
      text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
      text.valid_encoding? ? text : text.scrub("?")
    end

    # A tool returned images (read an image file, or a plugin's
    # ToolResult): store each with the session (the turn's VisionContext)
    # so the loop sends it. One that can't be sent adds a line saying why
    # and keeps the text and the other images; for read, whose text only
    # says the image is attached, that line replaces the text.
    # @return [Array(Hash, Array<Hash>)] the result and its refs
    # +vision+: the turn's VisionContext (TurnSettings#vision).
    def attach_images(call, result, vision)
      reason = if vision.nil? then "images can't be attached here"
               elsif !vision.sendable? then ImagePlan::CANT_SEE
               end
      refs = []
      notes = []
      Array(result[:images]).each_with_index do |entry, index|
        entry = ImageStore.symbolize(entry)
        unless valid_image_entry?(entry)
          notes << "Error: image #{index + 1} is not {path:} or {bytes:, name:}"
          next
        end

        description = entry[:description] || entry[:name] || (entry[:path] && File.basename(entry[:path])) || "image #{index + 1}"
        if reason
          notes << "#{description} is an image; #{reason}"
        elsif refs.size >= MAX_IMAGES_PER_RESULT
          notes << "#{description} is not attached: at most #{MAX_IMAGES_PER_RESULT} images per tool result"
        else
          refs << vision.ingest(entry[:path], name: entry[:name], bytes: entry[:bytes])
        end
      rescue ImageStore::Error => e
        notes << "Error: #{e.message}"
      end
      unless refs.empty?
        Log.info(:turn, "tool_images_attached", tool: call[:name], count: refs.size,
                                                bytes: refs.sum { |ref| ref[:bytes].to_i }, left_out: notes.size)
      end
      [result.merge(output: images_output(call, result, notes)), refs]
    end

    def valid_image_entry?(entry)
      return false unless entry.is_a?(Hash)

      (entry[:path].is_a?(String) && !entry[:path].empty?) || (entry[:bytes].is_a?(String) && !entry[:bytes].empty?)
    end

    def images_output(call, result, notes)
      return result[:output] if notes.empty?
      return "[#{call[:name]}] #{notes.first}" if result[:image_only] && notes.first.start_with?("Error: ")
      return "[#{call[:name]}]\n#{notes.first}" if result[:image_only]

      [result[:output], *notes].join("\n")
    end

    # The session's folder (the turn's TurnContext#cwd), else the
    # process's: a bare kernel (specs) has none.
    def session_cwd(context)
      cwd = context.cwd
      cwd.to_s.empty? ? Dir.pwd : cwd
    end

    # The kernel's tools, for the activity line of a tool that isn't built in.
    def tools = @kernel.tools

    # The turn's Tools::ToolSurface (+context+'s), else one computed now
    # from the kernel's tools (a runner outside an Engine turn).
    def surface(context) = Tools::ToolSurface.of(context, tools)

    # The call its tool's entry unwraps it to (call_tool on a built-in),
    # else the call as it is. On a host that loads tools, a direct call of
    # a source's tool by its acts_as runs as the call_tool call first
    # (Registry::Index#wrap): call_tool's row, rules and approvals. One
    # that fails runs as it is: call_tool then refuses a built-in (fail
    # closed).
    def unwrapped(call, context)
      return call if tools.nil? || call[:name].nil?

      surface = surface(context)
      call = wrapped(surface, call)
      surface.declared_entry(call[:name])&.unwrap&.call(call, surface.layers) || call
    rescue StandardError => e
      Log.warn(:turn, "tool_unwrap_failed", tool: call[:name].to_s, error: "#{e.class}: #{e.message}")
      call
    end

    # +call+ as the call_tool call it runs as when it names a deferred
    # source tool, on a host that loads tools; else as it is.
    def wrapped(surface, call)
      wrap = surface.index&.wrap
      return call unless wrap && surface.loads_tools && !surface.registered?(call[:name])

      wrap.call(call) || call
    end

    # A call that can't run in this turn as it is, by its name: a real tool
    # the session's toolkit leaves out, or one reached through call_tool
    # (via:) that the toolkit doesn't reach that way (a hook's rewrite). On
    # a host that loads tools, a built-in the toolkit reaches runs by its
    # own name (KernelLoop#dispatch takes it too).
    def left_out?(call, context)
      return false if tools.nil? || call[:name].nil?

      surface = surface(context)
      return surface.indexed_entry(call[:name]).nil? if call[:via]
      return false if surface.loads_tools && surface.indexed_entry(call[:name])

      surface.left_out?(call[:name])
    end

    def unreached_group_refusal(call, context)
      # A review turn's boundary denies it first (and words why); a pair
      # turn gets the owner's refusal.
      return if context.participant? && context.participant_mode != ParticipantMode::PAIR
      return if tools.nil?

      surface = surface(context)
      index = surface.index
      return unless index.respond_to?(:unreached_tool)

      name = if call[:name] == index.call_name
               args = call[:args].is_a?(Hash) ? call[:args] : {}
               args["tool"] || args[:tool]
             else
               call[:name]
             end
      tool = index.unreached_tool(name)
      tool && Tools::ToolIndex::ToolkitGroupRefusal.for(tool, surface)
    end

    # A tool the registry has from a plugin (not core, not unknown).
    def plugin_tool?(name)
      entry = tools && !name.nil? ? tools[name] : nil
      !entry.nil? && !entry.core?
    end

    # A plugin tool's label, what the UIs show for its raw name.
    def plugin_label(name) = ToolActivity.plugin_label(name, registry: tools)

    # The one leading line the model gets when the gate changed the call it
    # asked for: "ran as: <tool> <changed args>", or nil when nothing
    # changed. The args are the changed call's activity params, so the line
    # stays short.
    def changed_call_line(original, call)
      return nil if original == call

      params = ToolActivity.tool_activity_params(call[:name], call, registry: tools)
      ["ran as: #{call[:name]}", params].compact.join(" ")
    end

    # The kernel's gate (the Engine's, KernelLoop::Services#gate: its
    # context, the approval flow); a bare kernel (specs) gets one that only
    # runs its hooks, built per call from what the kernel holds now.
    def gate
      @kernel.guardrail_gate || Guardrails::Gate.new(hooks: @kernel.hooks, tools: tools)
    end

    # A gate that fails denies the call (fail closed).
    def evaluate(call, context, iteration, params)
      gate.evaluate(call, context: context, iteration: iteration, params: params)
    rescue StandardError => e
      Guardrails::Verdict.new(call: call).deny!("the guardrail check failed: #{e.class}: #{e.message}",
                                                decided_by: "core")
    end

    def settle_ask(verdict, context)
      gate.settle_ask(verdict, context: context)
    rescue StandardError => e
      verdict.settle!(:deny, decided_by: "core", note: "The approval failed (#{e.class}: #{e.message}).")
    end

    # An allowed ask: the activity says who allowed it, and for what scope.
    def approved(result, verdict)
      activity = result[:activity]
      activity = activity.merge(guardrail: verdict.to_activity) if activity.is_a?(Hash)
      result.merge(activity: activity)
    end

    # A legacy veto keeps its old text; a verdict's deny tells the model
    # who decided and not to route around it.
    def denied(call, verdict)
      if verdict.rule == Tools::ToolIndex::ToolkitGroupRefusal::RULE
        output = "[#{call[:name]}] #{verdict.reason}"
        activity = ToolActivity.tool_activity_event(call[:name], call, output, registry: tools)
        return { output: output, activity: activity.merge(status: "blocked", guardrail: verdict.to_activity) }
      end

      output = if verdict.legacy?
                 reason = verdict.reason.to_s.strip
                 "[#{call[:name]}] Error: blocked by guardrail: #{reason.empty? ? "blocked by hook" : reason}"
               else
                 "[#{call[:name]}] Error: #{verdict.deny_text}"
               end
      activity = ToolActivity.tool_activity_event(call[:name], call, output, registry: tools)
      { output: output, activity: activity.merge(status: "blocked", guardrail: verdict.to_activity) }
    end

    # KernelLoop#dispatch turns tool errors into "[name] Error: …" itself;
    # this rescue only catches a failing dispatcher.
    def dispatch(call, context)
      @kernel.dispatch_tool_call(call, context)
    rescue StandardError => e
      { output: "[#{call[:name]}] Error: #{e.class}: #{e.message}", activity: nil }
    end

    # A failing hook must not break the turn.
    def fire(name, event)
      Degrade.call(:hooks, "tool_hook_fire_failed", hook: name) { @kernel.hooks&.fire(name, event) }
    end

    # A failing stream callback (a UI gone) must not break the call either.
    def emit(callback, event)
      StreamEvent.emit(callback, event, failure: "tool_event_callback_failed")
    end
  end
end
