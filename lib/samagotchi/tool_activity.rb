# frozen_string_literal: true

require "json"
require_relative "log"
require_relative "tools/execute"
require_relative "tools/read"
require_relative "tools/write"
require_relative "tools/memory"
require_relative "tools/edit"
require_relative "tools/task_create"
require_relative "tools/task_get"
require_relative "tools/task_list"
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
    def tool_activity_event(tool_name, call, result, registry: nil)
      {
        action: tool_activity_action(tool_name, registry: registry),
        tool: tool_name,
        params: tool_activity_params(tool_name, call, registry: registry),
        status: tool_activity_status(result, tool_name)
      }
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
    # task_wait the user's Stop ended: the task itself runs on.
    def tool_activity_status(result, tool_name = nil)
      text = result.to_s
      return "error" if text.start_with?("Error:")
      return "error" if tool_name == Tools::Execute::NAME && execute_failed?(text)
      return "stopped" if tool_name == Tools::TaskWait::NAME && text.match?(/^wait_result: canceled$/)

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
