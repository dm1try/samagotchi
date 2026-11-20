# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attach_launcher"
require "samagotchi/worker_boot"
require_relative "support/task_dirs"

RSpec.describe "scratch background task cleanup" do
  include TaskDirs

  around { |example| with_task_dir { |dir| @root = dir and example.run } }

  let(:state_dir) { File.join(@root, "sessions") }
  let(:runtime) { Samagotchi::Tools::TaskRuntime }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: @root).tap do |s|
      s.scratch = true
      s.save(state_dir: state_dir)
    end
  end

  def start_task
    record, error = runtime.create_task("sleep 30 # private-command")
    raise error if error

    session.messages << { role: "tool_response", content: "[task_create]\ntask_id: #{record.id}" }
    session.save(state_dir: state_dir)
    record
  end

  shared_examples "stops scratch tasks" do |seat|
    it "#{seat} stops and logs a scratch task without its command" do
      record = start_task
      allow(Samagotchi::Log).to receive(:info).and_call_original
      allow(Samagotchi::Session).to receive(:default_state_dir).and_return(state_dir)

      case seat
      when :launcher
        Samagotchi::TerminalUI::AttachLauncher.end_scratch(session.id, state_dir: state_dir, out: StringIO.new)
      when :worker
        Samagotchi::WorkerBoot.send(:delete_left_scratch, session.id, state_dir: state_dir)
      when :one_shot
        Samagotchi::TerminalUI.allocate.send(:delete_scratch, session)
      end

      expect(File.exist?(Samagotchi::Session.session_file(session.id, state_dir: state_dir))).to be(false)
      expect(runtime.load_record(record.id)).to have_attributes(status: "stopped", stop_reason: "stopped_by_scratch")
      expect(Samagotchi::Log).to have_received(:info)
        .with(:worker, "scratch_task_stopped", sid: session.id, task_id: record.id).once
    end
  end

  it_behaves_like "stops scratch tasks", :launcher
  it_behaves_like "stops scratch tasks", :worker
  it_behaves_like "stops scratch tasks", :one_shot

  it "logs an unverified scratch task without signalling it" do
    record = start_task
    path = Samagotchi::TaskFiles.metadata_path(record.id)
    data = JSON.parse(File.read(path))
    data.delete("pid_started")
    File.write(path, JSON.generate(data))
    allow(Samagotchi::Log).to receive(:warn).and_call_original

    Samagotchi::WorkerBoot.send(:delete_left_scratch, session.id, state_dir: state_dir)

    expect(Samagotchi::ProcessGroup.alive?(record.pid)).to be(true)
    expect(Samagotchi::Log).to have_received(:warn)
      .with(:worker, "scratch_task_not_stopped", sid: session.id, task_id: record.id, why: :unverified).once
  end
end
