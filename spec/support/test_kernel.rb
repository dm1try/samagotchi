# frozen_string_literal: true

require "samagotchi/client"
require "samagotchi/kernel_loop"
require "samagotchi/reminder_store"

# The kernel and client an Engine spec hands in: a real KernelLoop (the
# contract the Engine talks to; stub #run on it as a partial double) and a
# Client double that answers the Engine's per-turn calls (the window probe,
# /props) with nothing, on a llama.cpp transport (as Client's default).
#
#   let(:client) { test_client }
#   let(:kernel) { test_kernel(client: client) }
#   before { allow(kernel).to receive(:run) { |messages, **| ... } }
module TestKernel
  # @param opts [Hash] more KernelLoop.new options (profile:, tools:, hooks:)
  def test_kernel(client: test_client, **)
    Samagotchi::KernelLoop.new(client: client, reminder_store: Samagotchi::ReminderStore.new, **)
  end

  # @param stubs [Hash] more Client methods and their answers
  def test_client(**stubs)
    instance_double(Samagotchi::Client, invalidate_context_window!: nil, server_props: nil, cached_server_props: nil, slot_status: nil,
                                        transport: Samagotchi::Client::Transport.new(:llama_cpp), **stubs)
  end
end

RSpec.configure { |config| config.include TestKernel }
