# frozen_string_literal: true

require "samagotchi/client"
require "samagotchi/kernel_loop"
require "samagotchi/reminder_store"
require "samagotchi/turn_context"

# The kernel and client an Engine spec hands in: a real KernelLoop (the
# contract the Engine talks to; stub #run on it as a partial double) and a
# Client double that answers the Engine's per-turn calls (the window probe,
# /props) with nothing.
#
#   let(:client) { test_client }
#   let(:kernel) { test_kernel(client: client) }
#   before { allow(kernel).to receive(:run) { |messages, **| ... } }
#
# A run outside an Engine turn takes its turn as a TurnContext
# (#run_context): kernel.run(messages, context: run_context(settings: …)),
# ChatLoop#complete(context:), ToolRunner#run(call, context:),
# Guardrails::Gate#evaluate(call, context:).
module TestKernel
  # @param opts [Hash] more KernelLoop.new options (profile:, tools:, hooks:)
  def test_kernel(client: test_client, **)
    Samagotchi::KernelLoop.new(client: client, reminder_store: Samagotchi::ReminderStore.new, **)
  end

  # A TurnContext outside an Engine turn (TurnContext.none): +settings+
  # (LLM::TurnSettings.none by default; a kernel's own are
  # kernel.turn_settings) and any other field given (session:, author:,
  # participant_mode:, cwd:, session_dir:, model_key:…).
  # @return [Samagotchi::TurnContext]
  def run_context(settings: Samagotchi::LLM::TurnSettings.none, **)
    Samagotchi::TurnContext.none(settings: settings, **)
  end

  # @param stubs [Hash] more Client methods and their answers
  def test_client(**stubs)
    instance_double(Samagotchi::Client, invalidate_context_window!: nil, server_props: nil, cached_server_props: nil, slot_status: nil, **stubs)
  end
end

RSpec.configure { |config| config.include TestKernel }
