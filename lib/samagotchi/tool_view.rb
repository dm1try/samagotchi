# frozen_string_literal: true

require_relative "command_steps"
require_relative "tools/execute"
require_relative "tools/task_create"

module Samagotchi
  # What a richer UI shows of a tool call beyond its one-line params: the
  # full command of an execute / task_create (whitespace kept), and the
  # call's own cwd: argument. Built by the server on every path (the live
  # tool_call_started, the bridge's snapshot and replay, a reload from the
  # saved call), so the UIs never parse the call themselves. params and its
  # 80-char cut stay as they are (the guardrails, "ran as:", the TUI).
  #
  # +truncated+: the command was longer than COMMAND_LIMIT and is cut to it;
  # +chars+ is then its full length. +cd+ and +steps+: the command as
  # CommandSteps reads it (its leading cd, its steps), both nil when it
  # can't (the fallback: the UI shows the command itself) or the command
  # is cut. +description+: what the model said the command does (execute's
  # optional description), whitespace collapsed, a trailing period gone;
  # nil when it gave none.
  ToolView = Data.define(:command, :cwd, :truncated, :chars, :cd, :steps, :description) do
    def to_h = super.merge(steps: steps&.map(&:to_h)).compact.reject { |_key, value| value == false }
  end

  class ToolView
    # The longest command a view carries (the spike's longest was 3,799).
    COMMAND_LIMIT = 8_000

    TOOLS = [Tools::Execute::NAME, Tools::TaskCreate::NAME].freeze

    # The longest description a view carries; a row's title shows the
    # first TITLE_LIMIT characters of it.
    DESCRIPTION_LIMIT = 300
    TITLE_LIMIT = 60

    # @return [ToolView, nil] nil for a tool without a view and for an
    #   empty command
    def self.for(tool_name, call)
      return nil unless TOOLS.include?(tool_name) && call.is_a?(Hash)

      command = call[:content].to_s
      return nil if command.strip.empty?

      cwd = call[:cwd].to_s.strip
      truncated = command.length > COMMAND_LIMIT
      parsed = truncated ? nil : CommandSteps.parse(command)
      new(command: truncated ? command[0, COMMAND_LIMIT] : command, cwd: cwd.empty? ? nil : cwd,
          truncated: truncated, chars: truncated ? command.length : nil, cd: parsed&.cd, steps: parsed&.steps,
          description: description(call))
    end

    # The call's description as a view shows it, nil for none.
    def self.description(call)
      text = call[:description]
      return nil unless text.is_a?(String)

      text = text.gsub(/\s+/, " ").strip.sub(/(?<!\.)\.\z/, "")
      return nil if text.empty?

      text.length > DESCRIPTION_LIMIT ? "#{text[0, DESCRIPTION_LIMIT - 1]}…" : text
    end

    # A row's title from the call's description: cut to TITLE_LIMIT, at a
    # word when one ends in its second half. nil for none.
    def self.description_title(call)
      text = description(call)
      return text if text.nil? || text.length <= TITLE_LIMIT

      cut = text[0, TITLE_LIMIT - 1]
      space = cut.rindex(" ")
      cut = cut[0, space] if space && space >= TITLE_LIMIT / 2
      "#{cut.sub(/[\s,;:.-]+\z/, "")}…"
    end
  end
end
