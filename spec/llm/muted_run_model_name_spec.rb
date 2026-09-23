# frozen_string_literal: true

require "samagotchi/terminal_ui"

# 7a: the TUI's muted reminder run (run_selected_backend) drove the native
# KernelLoop with the host-qualified name ("box:gemma4-26b"), which reached
# the server, ContextWindow.resolve and profile inference. It now goes through
# the backend like every turn and sends the bare name.
RSpec.describe "The muted reminder run's model name" do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "default" => { host: "localhost", port: 8080 },
      "box" => { host: "box.test", port: 8081 }
    })
  end

  around do |example|
    previous = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "box:gemma4-26b"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = previous
  end

  it "sends the bare model name to the native kernel" do
    ui = Samagotchi::TerminalUI.new(mode: :assist, host_registry: registry)
    kernel = ui.instance_variable_get(:@kernel)
    allow(kernel).to receive(:run).and_return(Samagotchi::KernelLoop::Result.new(output: "ok", conversation: []))

    ui.send(:run_selected_backend, [{ role: "user", content: "due" }],
            max_iterations: 1, on_stream_event: nil,
            cancel_controller: Samagotchi::Client::CancellationController.new)

    expect(kernel).to have_received(:run).with(anything, hash_including(model_name: "gemma4-26b"))
  end
end
