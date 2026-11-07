# frozen_string_literal: true

require "samagotchi/client"
require "samagotchi/kernel_loop"
require "samagotchi/reminder_store"
require "samagotchi/turn_context"
require "samagotchi/tools/tool_surface"

# The kernel and client an Engine spec hands in: a real KernelLoop (the
# contract the Engine talks to; stub #run on it as a partial double) and a
# Client double that answers the Engine's per-turn calls (the window probe,
# /props) with nothing.
#
#   let(:client) { test_client }
#   let(:kernel) { test_kernel(client: client) }
#   before { allow(kernel).to receive(:run) { |messages, **| ... } }
#
# What the Engine would hand the kernel (KernelLoop::Services: hooks:,
# tools:, gate:, peers:…) goes in as test_kernel's options, or onto a
# kernel already built with attach_services(kernel, tools: …).
#
# A run outside an Engine turn takes its turn as a TurnContext
# (#run_context): kernel.run(messages, context: run_context(settings: …)),
# ChatLoop#complete(context:), ToolRunner#run(call, context:),
# Guardrails::Gate#evaluate(call, context:).
module TestKernel
  # @param profile [ModelProfile, Symbol, String, nil] KernelLoop.new's
  # @param services [Hash] KernelLoop::Services fields (a fresh
  #   ReminderStore, the built-in tools and nothing else by default)
  def test_kernel(client: test_client, profile: nil, **services)
    Samagotchi::KernelLoop.new(client: client, profile: profile,
                               services: Samagotchi::KernelLoop::Services.none(reminder_store: Samagotchi::ReminderStore.new, **services))
  end

  # Swap some of +kernel+'s services (KernelLoop::Services fields), the
  # rest kept: KernelLoop#attach with them.
  # @return [Samagotchi::KernelLoop::Services]
  def attach_services(kernel, **fields)
    kernel.attach(kernel.services.with(**fields))
  end

  # A TurnContext outside an Engine turn (TurnContext.none): +settings+
  # (LLM::TurnSettings.none by default; a kernel's own are
  # kernel.turn_settings) and any other field given (session:, author:,
  # participant_mode:, cwd:, session_dir:, model_key:…). +tools+ (a
  # Tools::Registry, a kernel's are kernel.tools; nil: none): its surface, built as a
  # bare kernel builds its own (Tools::ToolSurface.bare, under the
  # settings' layers and loads_tools); a context handed to a loop, a
  # runner or a dispatch needs one (none raises Tools::MissingSurface).
  # @return [Samagotchi::TurnContext]
  def run_context(settings: Samagotchi::LLM::TurnSettings.none, **fields)
    context = Samagotchi::TurnContext.none(settings: settings, **fields.except(:tools))
    fields.key?(:tools) ? Samagotchi::Tools::ToolSurface.bare(context, fields[:tools]) : context
  end

  # @param stubs [Hash] more Client methods and their answers
  def test_client(**stubs)
    instance_double(Samagotchi::Client, invalidate_context_window!: nil, server_props: nil, cached_server_props: nil, slot_status: nil, **stubs)
  end
end

RSpec.configure { |config| config.include TestKernel }
