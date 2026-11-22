# frozen_string_literal: true

require "json"

# The compatibility corpus's compat-prompt session (ReleaseTools.write_compat_corpus!):
# a system head and the prompt parts its build recorded, each at its place in
# the head (PromptPart's at, len, lead, digest, head, params), so a later
# chi's part route slices it (spec/compat/readers_spec.rb).
module CompatPrompt
  ID = "compat-prompt"
  STAMP = "2026-01-01T00:00:00Z"

  module_function

  # Writes the session into +sessions_dir+ as +version+ wrote it.
  # @return [String] its file
  def write!(sessions_dir, version, at)
    require_relative "../../lib/samagotchi/prompt_part"
    require_relative "../../lib/samagotchi/session"
    lead = "System identity (auto-loaded, scope=system):\n"
    head = "Base.\n#{lead}I am chi."
    session = Samagotchi::Session.new(id: ID, mode: "assist", model_name: "compat:model", working_directory: "/compat-fixture",
                                      created_at: STAMP, updated_at: STAMP,
                                      messages: [{ role: "system", content: head }, { role: "user", content: "compatibility corpus" }])
    session.prompt_parts = parts(lead, Samagotchi::PromptPart.digest_of(head, 16))
    session.save(state_dir: sessions_dir, now: at)
    path = Samagotchi::Session.session_file(ID, state_dir: sessions_dir)
    data = JSON.parse(File.read(path))
    data["written_by"] = version
    data["updated_at"] = STAMP
    File.write(path, "#{JSON.pretty_generate(data)}\n")
    path
  end

  # The tools (a chat host's: no place), the base text and the identity memory.
  def parts(lead, head)
    part = Samagotchi::PromptPart
    dirs = { "requested_scope" => "system", "model_key" => nil, "fallback_model_key" => nil,
             "project_dir" => "/compat-fixture/memories/projects/compat", "system_dir" => "/compat-fixture/memories" }
    [part.build(kind: :tools, label: "1 declared", chars: 30, params: { "tools" => [{ "name" => "read", "chars" => 30 }] }),
     part.build(kind: :base, label: "base prompt", chars: 6, at: 0, len: 5, lead: 0, digest: part.digest_of("Base."), head: head),
     part.build(kind: :identity, label: "identity", ref: "identity", scope: "system", chars: lead.length + 9, at: 6,
                len: lead.length + 9, lead: lead.length, digest: part.digest_of("I am chi."), head: head, params: dirs)]
  end
end
