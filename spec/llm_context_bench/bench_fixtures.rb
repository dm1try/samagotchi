# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

# Small synthetic sessions for the llm_context bench specs (script/
# llm_context_bench): written by hand, never copied from a real session.
module BenchFixtures
  WORKDIR = "/home/dev/projects/shop"

  module_function

  def call(id, name, args) = { "id" => id, "name" => name, "arguments" => args }

  def model(content = "", calls: nil, thinking: nil)
    entry = { "role" => "model", "content" => content }
    entry["tool_calls"] = calls if calls
    entry["thinking"] = thinking if thinking
    entry
  end

  def result(call_id, content) = { "role" => "tool_response", "content" => content, "tool_call_id" => call_id }

  def user(content, kind: nil) = { "role" => "user", "content" => content, "kind" => kind }.compact

  # A chat session of two turns: turn 0 reads lib/cart.rb and runs its
  # spec, turn 1 reads it again and edits it.
  def chat_messages
    [
      { "role" => "system", "content" => "You are a coding agent." },
      user("Find why CartTotals rounds wrong."),
      model("", calls: [call("c1", "read", { "path" => "/home/dev/projects/shop-fix/lib/cart.rb" })], thinking: "Look at the cart."),
      result("c1", "[read] lib/cart.rb\n1: class CartTotals\n2:   def rounded_total = total.round(1)\n3: end"),
      model("", calls: [call("c2", "execute", { "command" => "bundle exec rspec spec/cart_spec.rb" })]),
      result("c2", "[execute]\nstdout:\n1 failure: expected 10.25, got 10.3 (rounded_total)"),
      model("rounded_total rounds to one place."),
      user("Fix it."),
      model("", calls: [call("c3", "read", { "path" => "lib/cart.rb" })]),
      result("c3", "[read] lib/cart.rb\n1: class CartTotals\n2:   def rounded_total = total.round(1)\n3: end"),
      model("", calls: [call("c4", "edit", { "path" => "lib/cart.rb", "old_str" => "round(1)", "new_str" => "round(2)" })]),
      result("c4", "[edit] lib/cart.rb: 1 line changed"),
      model("Fixed: rounded_total rounds to cents.")
    ]
  end

  def native_call(name, params)
    body = params.map { |key, value| "<parameter=#{key}>\n#{value}\n</parameter>" }.join("\n")
    "<tool_call>\n<function=#{name}>\n#{body}\n</function>\n</tool_call>"
  end

  # A native (Qwen XML) session: one batch of two calls answered by one
  # joined entry, then a second turn.
  def native_messages
    [
      { "role" => "system", "content" => "You are a coding agent." },
      user("List the specs and read the helper."),
      model("<think>Two calls.</think>\nLooking.\n#{native_call("execute", "command" => "ls spec")}\n" \
            "#{native_call("read", "path" => "spec/spec_helper.rb")}"),
      { "role" => "tool_response",
        "content" => "[execute]\nstdout:\ncart_spec.rb\nspec_helper.rb\n\n---\n\n[read] spec/spec_helper.rb\n1: require \"shop_helpers\"" },
      model("Two specs."),
      user("Run them."),
      model(native_call("execute", "command" => "ls spec")),
      { "role" => "tool_response", "content" => "[execute]\nstdout:\ncart_spec.rb\nspec_helper.rb" },
      model("Done.")
    ]
  end

  # Writes a session file into +dir+.
  # @return [String] its path
  def write_session(dir, messages:, model: "openrouter:acme/coder-1", id: SecureRandom.uuid)
    FileUtils.mkdir_p(dir)
    data = { "id" => id, "mode" => "repl", "model_name" => model, "working_directory" => WORKDIR,
             "created_at" => "2026-10-01T10:00:00Z", "updated_at" => "2026-10-01T11:00:00Z", "messages" => messages }
    path = File.join(dir, "#{id}.json")
    File.write(path, JSON.generate(data))
    path
  end
end
