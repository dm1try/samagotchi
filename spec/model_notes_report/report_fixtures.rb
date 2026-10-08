# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

# Small synthetic sessions for the model notes report specs (script/
# model_notes_report): written by hand, never copied from a real session.
module ReportFixtures
  WORKDIR = "/home/dev/projects/shop"
  NOTE = { "name" => "model_notes_deepseek", "scope" => "system", "chars" => 612, "digest" => "1a2b3c4d" }.freeze

  module_function

  def call(id, name, args) = { "id" => id, "name" => name, "arguments" => args }

  def model(content = "", calls: nil)
    entry = { "role" => "model", "content" => content }
    entry["tool_calls"] = calls if calls
    entry
  end

  def result(call_id, content = "ok") = { "role" => "tool_response", "content" => content, "tool_call_id" => call_id }

  def prompt(content, turn_id: nil, **marks) = { "role" => "user", "content" => content, "turn_id" => turn_id, **marks }.compact

  # A step of one call and its result.
  def step(id, name, args) = [model("", calls: [call(id, name, args)]), result(id)]

  def read(id) = step(id, "read", { "path" => "lib/cart.rb" })
  def edit(id) = step(id, "edit", { "path" => "lib/cart.rb", "old_str" => "round(1)", "new_str" => "round(2)" })
  def execute(id, command) = step(id, "execute", { "command" => command })

  # A build: two reads, an edit (call 3), a read, a commit (call 5), then
  # a backgrounded server and an answer. 7 steps, 6 calls.
  def build_messages(turn_id: "t-1")
    [
      { "role" => "system", "content" => "You are a coding agent." },
      prompt("Fix the rounding.", turn_id: turn_id),
      *read("c1"), *read("c2"), *edit("c3"), *read("c4"),
      *execute("c5", "git add -A && git commit -m \"Round to cents\""),
      *execute("c6", "bin/rails server &"),
      model("Fixed and committed.")
    ]
  end

  # Writes a session file into +dir+; +prompt_notes+ nil leaves the field
  # out (a file from before it), +turn_records+ writes <id>/analytics.json.
  # @return [String] its path
  def write_session(dir, messages:, id: SecureRandom.uuid, model: "openrouter:deepseek/deepseek-v4.1-flash",
                    created_at: "2026-10-05T10:00:00.000+02:00", prompt_notes: [NOTE], turn_records: nil)
    FileUtils.mkdir_p(dir)
    data = { "id" => id, "mode" => "repl", "model_name" => model, "working_directory" => WORKDIR,
             "created_at" => created_at, "updated_at" => created_at, "messages" => messages }
    data["prompt_notes"] = prompt_notes if prompt_notes
    path = File.join(dir, "#{id}.json")
    File.write(path, JSON.generate(data))
    if turn_records
      FileUtils.mkdir_p(File.join(dir, id))
      File.write(File.join(dir, id, "analytics.json"), JSON.generate("turns" => turn_records.size, "turn_records" => turn_records))
    end
    path
  end
end
