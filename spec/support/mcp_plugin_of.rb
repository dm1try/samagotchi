# frozen_string_literal: true

# The one place specs dig the MCP plugin instance out of an Engine. An
# Engine keeps no list of its plugins' instances (its @services hold
# their Service objects, each of which holds the block that started the
# plugin); this is the only place specs reach for it, and it stays here so
# the specs read `mcp_plugin_of(engine)` instead of the dig.
module McpPluginOf
  def mcp_plugin_of(engine)
    engine.instance_variable_get(:@services).to_a.first.instance_variable_get(:@start).binding.receiver
  end
end
