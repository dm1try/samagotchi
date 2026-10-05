# frozen_string_literal: true

require "json"
require_relative "log"
require_relative "command_steps"
require_relative "tool_view"
require_relative "tools/execute"
require_relative "tools/read"
require_relative "tools/write"
require_relative "tools/memory"
require_relative "tools/edit"
require_relative "tools/task_create"
require_relative "tools/task_get"
require_relative "tools/task_list"
require_relative "tools/task_runtime"
require_relative "tools/task_stop"
require_relative "tools/task_wait"
require_relative "tools/web_fetch"
require_relative "tools/ask_user_question"
require_relative "tools/list_sessions"
require_relative "tools/send_note"
require_relative "tools/delegate"
require_relative "tools/delegate_result"

module Samagotchi
  # The one-line summary of a tool call that the UIs show ("reading file",
  # path="…", ok/error/blocked). Both loops and KernelLoop#dispatch build it
  # from here. The built-ins have their own words below; any other tool in
  # the given Tools::Registry gets its entry's label and preview, or
  # "calling tool" and its arguments as key=value.
  module ToolActivity
    TOOL_ACTIVITY_PREVIEW_LIMIT = 80

    module_function

    # @param registry [Tools::Registry, nil] the session's tools
    # @param cwd [String, nil] what a file tool's title is relative to (the
    #   worker runs in its session's working directory)
    def tool_activity_event(tool_name, call, result, registry: nil, cwd: Dir.pwd)
      event = {
        action: tool_activity_action(tool_name, registry: registry),
        tool: tool_name,
        params: tool_activity_params(tool_name, call, registry: registry),
        status: tool_activity_status(result, tool_name)
      }
      title = tool_title(tool_name, call, cwd: cwd)
      event[:title] = title if title
      # The model's own words for a command, which the TUI's tool line
      # shows in place of the cut params.
      description = command_description(tool_name, call)
      event[:description] = description if description
      event
    end

    # An execute's description, cut as a row's title; nil for the rest.
    def command_description(tool_name, call)
      return nil unless call.is_a?(Hash) && ToolView::TOOLS.include?(tool_name)

      ToolView.description_title(call)
    end

    # What the call did, for a web row's one line ("edit lib/a.rb", the
    # command without its "cd … &&"): a file tool's path relative to +cwd+
    # when it is under it, a command's description (the model's few words),
    # else its first step and how many more (CommandSteps; its first line
    # when it has no steps), a memory's name, a task tool's task command
    # (task_title); nil for the other tools (a plugin's row keeps its preview, the
    # params). +params+ stays the full key=value line (the TUI, the
    # guardrails).
    def tool_title(tool_name, call, cwd: nil)
      return task_title(tool_name, call, cwd) if TASK_TOOLS.include?(tool_name)

      if [Tools::Execute::NAME, Tools::TaskCreate::NAME].include?(tool_name)
        title = command_description(tool_name, call) || steps_title(call[:content])
        return title if title
      end

      text = case tool_name
             when Tools::Read::NAME, Tools::MemoryRead::NAME then call[:content]
             when Tools::Write::NAME, Tools::Edit::NAME, Tools::MemoryWrite::NAME then call[:path]
             when Tools::Execute::NAME, Tools::TaskCreate::NAME then command_title(call[:content])
             end
      text = text.to_s.strip
      return nil if text.empty?

      case tool_name
      when Tools::Read::NAME, Tools::Write::NAME, Tools::Edit::NAME
        path = relative_path(text, cwd)
        path.length > TOOL_ACTIVITY_PREVIEW_LIMIT ? "…#{path[-(TOOL_ACTIVITY_PREVIEW_LIMIT - 1)..]}" : path
      else
        text = text.gsub(/\s+/, " ")
        text.length > TOOL_ACTIVITY_PREVIEW_LIMIT ? "#{text[0, TOOL_ACTIVITY_PREVIEW_LIMIT - 1]}…" : text
      end
    end

    TASK_TOOLS = [Tools::TaskWait::NAME, Tools::TaskGet::NAME, Tools::TaskStop::NAME].freeze

    # A task_wait / task_get / task_stop row's title: the task's command
    # (its record under +cwd+, the process's directory when nil) as a
    # command's title, and for a wait how long it waits ("npm test · up to
    # 600s"). nil when there is no record: the row keeps its id.
    def task_title(tool_name, call, cwd)
      command = Tools::TaskRuntime.command_of(call[:content], root: cwd)
      return nil unless command

      suffix = ""
      if tool_name == Tools::TaskWait::NAME
        timeout = call[:timeout].to_s.strip
        suffix = " · up to #{timeout.empty? ? Tools::TaskWait::TIMEOUT_DEFAULT : timeout.to_i}s"
      end
      room = TOOL_ACTIVITY_PREVIEW_LIMIT - suffix.length
      text = steps_title(command, room) || command_title(command).gsub(/\s+/, " ")
      return nil if text.empty?

      text = "#{text[0, room - 1]}…" if text.length > room
      "#{text}#{suffix}"
    end

    # A leading "cd <dir> &&" / "cd <dir>;" goes: the model's habit, and it
    # eats the line.
    LEADING_CD = /\Acd\s+(?:"[^"]*"|'[^']*'|\S+)\s*(?:&&|;)\s*/

    # "<first step> +N" (N the steps after it), cut to fit +limit+
    # (TOOL_ACTIVITY_PREVIEW_LIMIT); nil when the command has no steps.
    def steps_title(command, limit = TOOL_ACTIVITY_PREVIEW_LIMIT)
      steps = CommandSteps.parse(command)&.steps
      return nil unless steps

      first = steps.first.text.gsub(/\s+/, " ")
      more = steps.size > 1 ? " +#{steps.size - 1}" : ""
      room = limit - more.length
      first = "#{first[0, room - 1]}…" if first.length > room
      "#{first}#{more}"
    end

    def command_title(command)
      line = command.to_s.lines.map(&:strip).find { |l| !l.empty? }.to_s
      line.sub(LEADING_CD, "")
    end

    # +path+ relative to +cwd+ when it is inside it, compared by path
    # components ("/p/app-2" is not inside "/p/app"); else as given.
    def relative_path(path, cwd)
      return path if cwd.to_s.empty? || !path.start_with?("/")

      parts = File.expand_path(path).split("/")
      base = File.expand_path(cwd).split("/")
      return path unless parts.length > base.length && parts[0, base.length] == base

      parts.drop(base.length).join("/")
    end

    def tool_activity_action(tool_name, registry: nil)
      case tool_name
      when Tools::Execute::NAME then "running command"
      when Tools::Read::NAME then "reading file"
      when Tools::Write::NAME then "writing file"
      when Tools::Edit::NAME then "editing file"
      when Tools::MemoryRead::NAME then "reading memory"
      when Tools::MemoryWrite::NAME then "saving memory"
      when Tools::TaskCreate::NAME then "starting background task"
      when Tools::TaskGet::NAME then "checking task"
      when Tools::TaskList::NAME then "listing tasks"
      when Tools::TaskStop::NAME then "stopping task"
      when Tools::TaskWait::NAME then "waiting for task"
      when Tools::WebFetch::NAME then "fetching URL"
      when Tools::AskUserQuestion::NAME then "asking user"
      when Tools::ListSessions::NAME then "listing sessions"
      when Tools::SendNote::NAME then "sending a note"
      when Tools::Delegate::NAME then "delegating"
      when Tools::DelegateResult::NAME then "waiting for a delegate"
      else registry_entry(registry, tool_name)&.label || "calling tool"
      end
    end

    # "error" for an "Error:" result, and for an execute whose command
    # exited non-zero (its last "exit: N" line; no number: killed by a
    # signal), so the turn tally's "(N failed)" counts it. "stopped" for a
    # task_wait the user's Stop ended (the task itself runs on), for one
    # whose task was stopped (the stop-task button, or the model's task_stop),
    # and for a command the user's Stop killed or kept from starting: a
    # cancel, not a failure (its text still starts "Error:" for the model).
    def tool_activity_status(result, tool_name = nil)
      text = result.to_s
      return "stopped" if text == Tools::Execute::NOT_RUN_ON_STOP
      return "stopped" if tool_name == Tools::Execute::NAME && text.start_with?(Tools::Execute::STOPPED_BY_USER)
      return "error" if text.start_with?("Error:")
      return "error" if tool_name == Tools::Execute::NAME && execute_failed?(text)
      return "stopped" if tool_name == Tools::TaskWait::NAME && text.match?(/^(wait_result: canceled|status: stopped)$/)

      "ok"
    end

    def execute_failed?(text)
      exit_line = text.lines.reverse_each.find { |line| line.start_with?("exit: ") }
      return false unless exit_line

      code = exit_line[/\Aexit: (\d*)/, 1]
      code != "0"
    end

    def tool_activity_params(tool_name, call, registry: nil)
      case tool_name
      when Tools::Execute::NAME
        "command=#{preview_tool_param(call[:content])}"
      when Tools::Read::NAME
        parts = ["path=#{preview_tool_param(call[:content])}"]
        range = format_line_range(call)
        parts << "lines=#{range}" if range
        parts.join(" ")
      when Tools::Write::NAME
        "path=#{preview_tool_param(call[:path])}"
      when Tools::Edit::NAME
        parts = ["path=#{preview_tool_param(call[:path])}"]
        range = format_line_range(call)
        parts << "lines=#{range}" if range
        parts.join(" ")
      when Tools::MemoryRead::NAME
        parts = []
        name = call[:content].to_s.strip
        parts << "name=#{preview_tool_param(name)}" unless name.empty?
        scope = call[:scope].to_s.strip
        parts << "scope=#{preview_tool_param(scope)}" unless scope.empty?
        parts.join(" ")
      when Tools::MemoryWrite::NAME
        parts = []
        path = call[:path].to_s.strip
        parts << "name=#{preview_tool_param(path)}" unless path.empty?
        scope = call[:scope].to_s.strip
        parts << "scope=#{preview_tool_param(scope)}" unless scope.empty?
        desc = call[:description].to_s.strip
        parts << "description=#{preview_tool_param(desc)}" unless desc.empty?
        parts.join(" ")
      when Tools::TaskCreate::NAME
        parts = ["command=#{preview_tool_param(call[:content])}"]
        cwd = call[:cwd].to_s.strip
        parts << "cwd=#{preview_tool_param(cwd)}" unless cwd.empty?
        env = call[:env].to_s.strip
        parts << "env=#{preview_tool_param(env)}" unless env.empty?
        parts.join(" ")
      when Tools::TaskGet::NAME, Tools::TaskStop::NAME
        "id=#{preview_tool_param(call[:content])}"
      when Tools::TaskWait::NAME
        parts = ["id=#{preview_tool_param(call[:content])}"]
        timeout = call[:timeout].to_s.strip
        tail_lines = call[:tail_lines].to_s.strip
        done_pattern = call[:done_pattern].to_s.strip
        parts << "timeout=#{preview_tool_param(timeout)}" unless timeout.empty?
        parts << "tail_lines=#{preview_tool_param(tail_lines)}" unless tail_lines.empty?
        parts << "done_pattern=#{preview_tool_param(done_pattern)}" unless done_pattern.empty?
        parts.join(" ")
      when Tools::TaskList::NAME
        nil
      when Tools::WebFetch::NAME
        "url=#{preview_tool_param(call[:content])}"
      when Tools::ListSessions::NAME
        call[:cwd].to_s.strip.empty? ? nil : "cwd=#{preview_tool_param(call[:cwd])}"
      when Tools::SendNote::NAME
        "session=#{preview_tool_param(call[:session])} text=#{preview_tool_param(call[:content])}"
      when Tools::Delegate::NAME
        parts = []
        parts << "session=#{preview_tool_param(call[:session])}" unless call[:session].to_s.strip.empty?
        parts << "model=#{preview_tool_param(call[:model])}" unless call[:model].to_s.strip.empty?
        parts << "task=#{preview_tool_param(call[:content])}"
        parts << "wait=#{preview_tool_param(call[:wait])}" unless call[:wait].nil? || call[:wait].to_s.strip.empty?
        parts.join(" ")
      when Tools::DelegateResult::NAME
        call[:session].to_s.strip.empty? ? nil : "session=#{preview_tool_param(call[:session])}"
      when Tools::AskUserQuestion::NAME
        parts = ["question=#{preview_tool_param(call[:question] || call[:content])}"]
        opts = call[:options]
        parts << "options=#{preview_tool_param(Array(opts).join(","))}" if opts && !Array(opts).empty?
        parts.join(" ")
      else
        registry_params(registry_entry(registry, tool_name), call)
      end
    end

    def registry_entry(registry, tool_name) = registry && !tool_name.nil? ? registry[tool_name] : nil

    # A plugin tool's label ("chrome: screenshot"), what the UIs show for
    # its raw name; nil for a built-in, an unknown tool or an empty label.
    def plugin_label(tool_name, registry:)
      entry = registry_entry(registry, tool_name)
      label = entry && !entry.core? ? entry.label.to_s.strip : ""
      label.empty? ? nil : label
    end

    # A registry tool's params: its preview, else each given argument as
    # key="value" (the parsers' args:, which a registry-less reader such as
    # the web's reload also has); nil for a tool the registry doesn't know
    # that has no args:, and for a built-in without its own words above
    # (the reminder tools).
    def registry_params(entry, call)
      return nil if entry&.core?
      return nil if entry.nil? && !call[:args].is_a?(Hash)

      if entry&.preview
        begin
          return entry.preview.call(call)
        rescue StandardError => e
          Log.warn(:plugins, "plugin_preview_failed", tool: entry.name, error: e.class.name,
                                                      msg: "#{entry.name} preview failed: #{e.message}")
        end
      end

      given = call[:args].is_a?(Hash) ? call[:args] : call.except(:name)
      parts = given.filter_map do |key, value|
        next if value.nil? || value.to_s.strip.empty?

        "#{key}=#{preview_tool_param(value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value)}"
      end
      parts.empty? ? nil : parts.join(" ")
    end

    def format_line_range(call)
      start_line = call[:start_line].to_s.strip
      end_line = call[:end_line].to_s.strip
      return nil if start_line.empty? && end_line.empty?

      "#{start_line.empty? ? "?" : start_line}-#{end_line.empty? ? "?" : end_line}"
    end

    def preview_tool_param(value)
      text = value.to_s.gsub(/\s+/, " ").strip
      return '""' if text.empty?

      if text.length > TOOL_ACTIVITY_PREVIEW_LIMIT
        text = "#{text[0, TOOL_ACTIVITY_PREVIEW_LIMIT - 1]}…"
      end
      text.inspect
    end
  end
end
