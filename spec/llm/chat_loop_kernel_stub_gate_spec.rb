# frozen_string_literal: true

# A stub on a kernel member ChatLoop no longer asks goes silent:
# verify_partial_doubles raises only for a method the kernel no longer has,
# and KernelLoop keeps client, llm_context_view, apply_llm_context!,
# turn_settings, reprefilled_tokens, hooks and tools for its own loop. So
# while the ToolHost refactor (~/.claude/plans/arch-toolhost.md, r2 M4)
# moves those off the kernel for ChatLoop, a spec that builds a ChatLoop and
# stubs one of them on a kernel is checked here: each such stub must be one
# ALLOWED still counts (the member ChatLoop still asks the kernel for), and
# the counts shrink to nothing as the commits land. (A module: constants in
# a describe block would be top-level ones.)
module ChatLoopStubGate
  ROOT = File.expand_path("../..", __dir__)

  MEMBERS = %w[client llm_context_view apply_llm_context! turn_settings reprefilled_tokens hooks tools].freeze

  # The stubs still meant, per member: ChatLoop still asks the kernel.
  ALLOWED = { "hooks" => 6, "tools" => 2 }.freeze

  STUB = /(?:allow|expect)\((\w*kernel\w*)\)\.to\s+receive\(:(#{MEMBERS.map { |m| Regexp.escape(m) }.join("|")})\)/
  STUBS = /(?:allow|expect)\((\w*kernel\w*)\)\.to\s+receive_messages\(([^)]*)\)/
end

RSpec.describe "ChatLoop specs' kernel stubs" do
  def chat_loop_specs
    Dir.glob(["spec/**/*_spec.rb", "lib/samagotchi/bundles/*/spec/**/*_spec.rb"], base: ChatLoopStubGate::ROOT)
       .reject { |path| path == "spec/llm/chat_loop_kernel_stub_gate_spec.rb" }
       .select { |path| File.read(File.join(ChatLoopStubGate::ROOT, path)).include?("ChatLoop") }
  end

  def stubs
    chat_loop_specs.flat_map do |path|
      File.readlines(File.join(ChatLoopStubGate::ROOT, path)).each_with_index.flat_map do |line, index|
        members = line.scan(ChatLoopStubGate::STUB).map(&:last)
        line.scan(ChatLoopStubGate::STUBS).each do |(_, keys)|
          members.concat(keys.scan(/(\w+!?):/).flatten & ChatLoopStubGate::MEMBERS)
        end
        members.map { |member| [member, "#{path}:#{index + 1}"] }
      end
    end
  end

  it "stubs on a ChatLoop spec's kernel only the members ChatLoop still asks it for" do
    found = stubs.group_by(&:first).transform_values(&:size)
    expect(found).to eq(ChatLoopStubGate::ALLOWED), stubs.reject { |(member, _)| ChatLoopStubGate::ALLOWED.key?(member) }.map(&:last).join("\n")
  end
end
