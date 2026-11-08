# frozen_string_literal: true

require "prism"

# What ChatLoop (lib/samagotchi/llm/chat_loop.rb) reaches of KernelLoop, read
# from its source with Prism: each call on @kernel (`@kernel.x`, `@kernel&.x`),
# each call that takes @kernel itself as an argument (`ToolRunner.new(@kernel)`),
# each constant that names KernelLoop (`KernelLoop`, `KernelLoop::X`,
# `Samagotchi::KernelLoop`) and the require of kernel_loop.rb. The ToolHost
# refactor (~/.claude/plans/arch-toolhost.md) shrinks the list per commit; a
# new reach into the kernel fails here first. (A module: constants in a
# describe block would be top-level ones.)
module ChatLoopKernelReach
  SOURCE = File.expand_path("../../lib/samagotchi/llm/chat_loop.rb", __dir__)

  # The list as it stands: "@kernel.name" for a call on the kernel,
  # "Callee(@kernel)" for the kernel as an argument, "KernelLoop.name" /
  # "KernelLoop::Name" for a constant, "require kernel_loop".
  REACH = [
    "@kernel.apply_llm_context!",
    "@kernel.client",
    "@kernel.guard_generation",
    "@kernel.hooks",
    "@kernel.llm_context_turn=",
    "@kernel.llm_context_view",
    "@kernel.reprefilled_tokens",
    "@kernel.respond_to?",
    "@kernel.strip_model_thought",
    "@kernel.tools",
    "@kernel.turn_settings",
    "KernelLoop.resolve_output_char_cap",
    "ToolRunner.new(@kernel)",
    "require kernel_loop"
  ].freeze

  # Collects the reach from a Prism tree.
  class Reach < Prism::Visitor
    attr_reader :found

    def initialize
      super
      @found = []
    end

    def visit_call_node(node)
      @found << "@kernel.#{node.name}" if kernel?(node.receiver)
      args = node.arguments&.arguments || []
      @found << "#{callee(node)}(@kernel)" if args.any? { |arg| kernel?(arg) }
      if %i[require require_relative].include?(node.name) && args.first.is_a?(Prism::StringNode) &&
         args.first.unescaped.end_with?("kernel_loop")
        @found << "require kernel_loop"
      end
      return super unless kernel_loop_constant?(node.receiver)

      # The constant is the call's, counted once: its arguments and block only.
      @found << "KernelLoop.#{node.name}"
      node.arguments&.accept(self)
      node.block&.accept(self)
    end

    def visit_constant_read_node(node)
      @found << "KernelLoop" if node.name == :KernelLoop
      super
    end

    def visit_constant_path_node(node)
      return @found << "KernelLoop" if node.name == :KernelLoop
      return @found << "KernelLoop::#{node.name}" if kernel_loop_constant?(node.parent)

      super
    end

    private

    def kernel?(node) = node.is_a?(Prism::InstanceVariableReadNode) && node.name == :@kernel

    def kernel_loop_constant?(node)
      (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) && node.name == :KernelLoop
    end

    def callee(node)
      receiver = node.receiver
      prefix = receiver.respond_to?(:full_name) ? "#{receiver.full_name}." : ""
      "#{prefix}#{node.name}"
    end
  end
end

RSpec.describe "ChatLoop's reach into KernelLoop" do
  def reach(source)
    visitor = ChatLoopKernelReach::Reach.new
    Prism.parse(source).value.accept(visitor)
    visitor.found.uniq.sort
  end

  it "reaches the kernel only through these" do
    expect(reach(File.read(ChatLoopKernelReach::SOURCE))).to eq(ChatLoopKernelReach::REACH.sort)
  end

  it "sees each kind of reach (the reader itself)" do
    source = <<~RUBY
      require_relative "../kernel_loop"
      class X
        def a = @kernel.tools
        def b = @kernel&.hooks
        def c = ToolRunner.new(@kernel, window: 1)
        def d = KernelLoop.resolve_output_char_cap(nil)
        def e = Samagotchi::KernelLoop::Services
        def f = KernelLoop
        def g = @other.tools
      end
    RUBY

    expect(reach(source)).to eq(["@kernel.hooks", "@kernel.tools", "KernelLoop", "KernelLoop.resolve_output_char_cap",
                                 "KernelLoop::Services", "ToolRunner.new(@kernel)", "require kernel_loop"])
  end
end
