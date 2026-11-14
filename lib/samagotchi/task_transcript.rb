# frozen_string_literal: true

require_relative "tool_names"

module Samagotchi
  # Which background tasks a conversation started, read from its tool
  # results: a task_create's "task_id:" and an execute's hand-over at its
  # limit (or early, for a message). Text only: no record is read and no
  # process looked at (Tools::TaskRuntime.running_created_in adds the
  # refresh). The worker's finish wake (TaskWatch, WorkerTaskWakes), the
  # Bridge's stop-task check, a turn's cancel note and SessionManager's
  # running-task check read it. web/public/task_stop.js has the JS twin of
  # handed_over_id (handedOverId).
  module TaskTranscript
    # A task_create result as the model gets it: its "[task_create]" lead,
    # after the one "ran as: …" line a gate-corrected call has.
    RAN_AS_LINE = "(?:ran as: [^\n]*\n)?"
    CREATED_BLOCK = /\A#{RAN_AS_LINE}\[task_create\]\ntask_id: (\S+)/
    CREATED_OUTPUT = /\A#{RAN_AS_LINE}(?:\[task_create\]\n)?task_id: (\S+)/

    module_function

    # The ids of every task this conversation started (task_create, a
    # handed-over execute), whatever their status now, oldest first.
    # A native tool_response joins its calls' results with "---".
    # @return [Array<String>]
    def created_ids_in(messages)
      Array(messages).flat_map do |message|
        next [] unless (message[:role] || message["role"]).to_s == "tool_response"

        (message[:content] || message["content"]).to_s.split("\n\n---\n\n").filter_map do |block|
          block[CREATED_BLOCK, 1] || handed_over_id(block)
        end
      end.uniq
    end

    # The task id of a tool output that started a task, the "[tool]" lead
    # optional (a UI's row has it or not): a task_create's, or an execute's
    # handed_over_id. nil for any other tool or output.
    # @return [String, nil]
    def created_id(tool, text)
      case tool
      when "task_create" then text.to_s[CREATED_OUTPUT, 1]
      when ToolNames::Execute::NAME then handed_over_id(text)
      end
    end

    # The task id an execute's hand-over result names: anchored on its
    # first line (ToolNames::Execute::HANDED_OVER), never a "task_id:" line
    # anywhere, which the command's own output can print. The "[execute]"
    # lead and a "ran as: …" line before it are optional.
    # web/public/task_stop.js has the JS twin (handedOverId).
    # @return [String, nil]
    def handed_over_id(text)
      text = text.to_s
      # A regexp raises on bytes that aren't UTF-8 (a command's raw output).
      text = text.scrub unless text.valid_encoding?
      text[handed_over_pattern, 1]
    end

    def handed_over_pattern
      @handed_over_pattern ||= /\A#{RAN_AS_LINE}(?:\[#{ToolNames::Execute::NAME}\]\n)?#{Regexp.escape(ToolNames::Execute::HANDED_OVER)} #{ToolNames::Execute::HANDED_OVER_AFTER}[^\n]*\ntask_id: (\S+)/
    end

    private_class_method :handed_over_pattern
  end
end
