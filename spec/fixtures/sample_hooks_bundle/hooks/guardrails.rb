class Guardrails
  def call(event)
    raise "blocked by sample guardrail" if event[:tool_name] == "bad_tool" || event["tool_name"] == "bad_tool"
  end
end
