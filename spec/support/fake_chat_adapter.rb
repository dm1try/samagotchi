# frozen_string_literal: true

require "samagotchi/llm/openai_chat"

# Stands in for LLM::OpenAIChat in chat-loop specs: answers #chat with queued
# steps (a ChatResponse, an exception to raise, or a proc called with
# cancel_controller:, on_delta:, on_retry: that returns either), streaming each
# response's reasoning and text as one delta. The last step repeats. Records
# every request.
class FakeChatAdapter
  attr_reader :requests

  def self.text(text, reasoning: "", usage: Samagotchi::LLM::Usage.none)
    Samagotchi::LLM::ChatResponse.new(text: text, reasoning: reasoning, tool_calls: [], usage: usage, finish_reason: "stop")
  end

  # calls: [[id, name, arguments], ...]
  def self.tools(*calls, text: "")
    tool_calls = calls.map { |id, name, arguments| Samagotchi::LLM::ToolCall.new(id: id, name: name, arguments: arguments) }
    Samagotchi::LLM::ChatResponse.new(text: text, reasoning: "", tool_calls: tool_calls, usage: Samagotchi::LLM::Usage.none,
                                      finish_reason: "tool_calls")
  end

  def initialize(*steps)
    @steps = steps
    @requests = []
  end

  def base_url = "http://fake.test/v1"

  def chat(messages:, model:, tools: [], cancel_controller: nil, on_delta: nil, on_retry: nil, options: {})
    @requests << { messages: messages, model: model, tools: tools, options: options }
    step = @steps.length > 1 ? @steps.shift : @steps.first
    step = step.call(cancel_controller: cancel_controller, on_delta: on_delta, on_retry: on_retry) if step.respond_to?(:call)
    raise step if step.is_a?(Exception)

    payload = step.usage.source == :server ? { "usage" => { "prompt_tokens" => step.usage.prompt_tokens, "completion_tokens" => step.usage.completion_tokens } } : {}
    on_delta&.call(content: step.text, reasoning: step.reasoning, payload: payload)
    step
  end
end
