# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "rack/mock"
require "spec_helper"
require "samagotchi/session_setup"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/send_command"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attach_launcher"
require "samagotchi/web/app"
require_relative "support/worker_links"

# Every place a session starts × every SessionSetup member: where the
# member's value comes from there. A new member fails "has a cell for every
# member" until each entrypoint says what it does with it, so no path drops
# it unnoticed (the bug class: "flag ignored on path X").
#
# Cells: :given (the request's input, through SessionSetup.from_request),
# :inherited (the source session's, SessionSetup.of), :fixed (the site sets
# it, whatever was asked), :default (left at SessionSetup.new's) and
# :not_applicable (the entrypoint takes no such input: the member stays at
# its default). A non-obvious cell is [cell, reason].
module SessionSetupEntrypoints
  NOT_REQUESTED = "no request carries it: /reasoning-history after creation"
  NO_PINS = "pins are made in a running session"
  ORIGIN = "chosen with a toolkit; without one spawn_session stores toolkit.default as default"

  # (a) a person's new-session request: SessionSetup.from_request.
  REQUEST = {
    attached: { # chi, chi -p (TerminalUI::AttachLauncher.connect)
      llm_context: :given, thinking: :given, reasoning_history: [:not_applicable, NOT_REQUESTED],
      appended_prompt_files: :given, preloaded_memory_names: :given, muted_memory_names: :given, toolkit: :given,
      toolkit_origin: [:given, ORIGIN], settings: :given, parent_answers: :given,
      working_set_pins: [:not_applicable, NO_PINS]
    },
    one_shot: { # chi -p X --non-interactive (TerminalUI#new_session_setup)
      llm_context: :given, thinking: :given, reasoning_history: [:not_applicable, NOT_REQUESTED],
      appended_prompt_files: :given, preloaded_memory_names: :given, muted_memory_names: :given, toolkit: :given,
      toolkit_origin: [:given, "chosen with a toolkit, else toolkit.default filled in here as default " \
                               "(Session.new_session, not spawn_session)"],
      settings: :given, parent_answers: :given, working_set_pins: [:not_applicable, NO_PINS]
    },
    send_new: { # chi send --new (SendCommand#new_session_spec; a remote's goes as SetupWords to web_create)
      llm_context: :given, thinking: :given, reasoning_history: [:not_applicable, NOT_REQUESTED],
      appended_prompt_files: [:not_applicable, "a sender's flags: no --append-system-prompt"],
      preloaded_memory_names: [:not_applicable, "no --memory on chi send"],
      muted_memory_names: [:not_applicable, "no --mute on chi send"], toolkit: :given,
      toolkit_origin: [:given, ORIGIN], settings: :given, parent_answers: :given,
      working_set_pins: [:not_applicable, NO_PINS]
    },
    web_create: { # POST /api/sessions (SessionCreate#handle_create; a remote attach's create too)
      llm_context: :given, thinking: :given, reasoning_history: [:not_applicable, NOT_REQUESTED],
      appended_prompt_files: [:not_applicable, "paths of a terminal's machine: local-only (Contract::RUN)"],
      preloaded_memory_names: [:not_applicable, "--memory is local-only (Contract::RUN)"],
      muted_memory_names: [:not_applicable, "--mute is local-only (Contract::RUN)"], toolkit: :given,
      toolkit_origin: [:given, ORIGIN], settings: :given, parent_answers: :given,
      working_set_pins: [:not_applicable, NO_PINS]
    }
  }.freeze

  # (b) derived from another session (SessionSetup.of), (c) fixed or special.
  OTHER = {
    web_review_create: { # POST /api/sessions with review, no from: web_create's setup, then ReviewStart.start
      llm_context: :given, thinking: :given, reasoning_history: [:not_applicable, NOT_REQUESTED],
      appended_prompt_files: :not_applicable, preloaded_memory_names: :not_applicable,
      muted_memory_names: :not_applicable, toolkit: :given,
      toolkit_origin: [:fixed, "chosen: a review session is never offered a toolkit suggestion"],
      settings: :given, parent_answers: :given, working_set_pins: [:not_applicable, NO_PINS]
    },
    chi_review: { # chi review FILE… (ReviewStart.start from SessionAccess::Local#create_review): no setup flags
      llm_context: :not_applicable, thinking: :not_applicable, reasoning_history: :not_applicable,
      appended_prompt_files: :not_applicable, preloaded_memory_names: :not_applicable,
      muted_memory_names: :not_applicable, toolkit: :not_applicable,
      toolkit_origin: [:fixed, "chosen, as web_review_create"], settings: :not_applicable,
      parent_answers: :not_applicable, working_set_pins: :not_applicable
    },
    continue: { # SessionContinue (chi send --continues, /continue, the web's continue, schedules)
      llm_context: :inherited, thinking: :inherited, reasoning_history: :inherited,
      appended_prompt_files: :inherited, preloaded_memory_names: :inherited, muted_memory_names: :inherited,
      toolkit: [:inherited, "Toolkit.of: one from before toolkits is full, not today's default"],
      toolkit_origin: [:fixed, "inherited (SessionSetup::CARRY)"], settings: :inherited, parent_answers: :inherited,
      working_set_pins: :inherited
    },
    plugin_fork: { # ctx.sessions.fork (Engine's plugin host: SessionSetup.of(session, forked: true))
      llm_context: :inherited, thinking: :inherited, reasoning_history: :inherited,
      appended_prompt_files: :inherited,
      preloaded_memory_names: [:inherited, "less the delegate memory: a fork's parent_id would mark it a delegate"],
      muted_memory_names: :inherited, toolkit: :inherited, toolkit_origin: [:fixed, "inherited (SessionSetup::CARRY)"],
      settings: :inherited, parent_answers: :inherited, working_set_pins: :inherited
    },
    review_fork: { # chi review --from ID, the web's review fork (ReviewStart.fork)
      llm_context: :inherited, thinking: :inherited, reasoning_history: :inherited,
      appended_prompt_files: :inherited,
      preloaded_memory_names: [:fixed, "[]: a review starts from the recap, not the working session's memories"],
      muted_memory_names: :inherited, toolkit: :inherited, toolkit_origin: [:fixed, "chosen, as web_review_create"],
      settings: :inherited, parent_answers: :inherited, working_set_pins: :inherited
    },
    delegate: { # the delegate tool's child (Tools::Delegate.start_child)
      llm_context: [:default, "a child runs on its own model's settings"], thinking: :default,
      reasoning_history: :default, appended_prompt_files: :default,
      preloaded_memory_names: [:fixed, "Delegate::CHILD_MEMORIES"], muted_memory_names: :default,
      toolkit: [:given, "the call's toolkit:, else spawn_session's toolkit.child"],
      toolkit_origin: [:given, "chosen with the call's toolkit, else default"], settings: :default,
      parent_answers: [:inherited, "the parent's as it is then: held at least as tight"],
      working_set_pins: :default
    },
    verify_fresh: { # a Verify fresh child (VerifyFresh.start)
      llm_context: :default, thinking: :default, reasoning_history: :default, appended_prompt_files: :default,
      preloaded_memory_names: [:fixed, "the delegate memory"], muted_memory_names: :default, toolkit: :default,
      toolkit_origin: :default, settings: :default,
      parent_answers: [:inherited, "the parent's, as a delegate child's"], working_set_pins: :default
    },
    bundle_test: { # Testing::Bundle#setup_with (chi bundle test's recorder)
      llm_context: :not_applicable, thinking: :not_applicable, reasoning_history: :not_applicable,
      appended_prompt_files: :not_applicable, preloaded_memory_names: :not_applicable,
      muted_memory_names: :not_applicable, toolkit: :not_applicable, toolkit_origin: :not_applicable,
      settings: [:given, "the test's session_settings, as this bundle's"], parent_answers: :not_applicable,
      working_set_pins: :not_applicable
    }
  }.freeze

  TABLE = REQUEST.merge(OTHER).freeze
  CELLS = %i[given inherited fixed default not_applicable].freeze

  def self.cell(entrypoint, member) = Array(TABLE.fetch(entrypoint).fetch(member)).first
end

RSpec.describe Samagotchi::SessionSetup, "entrypoints × members" do
  include WorkerLinks

  let(:settings) { Samagotchi::SessionConfig::Settings.new(core: { "recap.enabled" => false }) }
  let(:toolkit) { Samagotchi::Toolkit.new(name: "lean") }
  let(:state_dir) { Dir.mktmpdir("setup-entrypoints") }

  after { FileUtils.rm_rf(state_dir) }

  it "has a cell for every member at every entrypoint" do
    SessionSetupEntrypoints::TABLE.each do |entrypoint, cells|
      expect(cells.keys).to match_array(described_class.members), "#{entrypoint}: #{described_class.members - cells.keys} missing"
      cells.each_value { |value| expect(SessionSetupEntrypoints::CELLS).to include(Array(value).first), "#{entrypoint}: #{value.inspect}" }
    end
  end

  it "takes every member a request entrypoint is given as a from_request keyword" do
    given = SessionSetupEntrypoints::REQUEST.values.flat_map { |cells| cells.select { |_, value| Array(value).first == :given }.keys }.uniq
    keywords = described_class.method(:from_request).parameters.map(&:last)
    names = { preloaded_memory_names: :memories, muted_memory_names: :muted, toolkit_origin: :toolkit }
    expect(keywords).to match_array(given.map { |member| names.fetch(member, member) }.uniq)
  end

  # A request with everything given: each :given member set, every other
  # at its default.
  def expect_cells(entrypoint, setup)
    blank = described_class.new
    described_class.members.each do |member|
      value = setup.public_send(member)
      if SessionSetupEntrypoints.cell(entrypoint, member) == :given
        expect(value).not_to eq(blank.public_send(member)), "#{entrypoint}: #{member} dropped"
      else
        expect(value).to eq(blank.public_send(member)), "#{entrypoint}: #{member} is #{value.inspect}"
      end
    end
  end

  it "gives the attached start every flag it takes" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    setups = []
    allow(Samagotchi::SessionManager).to receive(:spawn_session) { |**kwargs| (setups << kwargs[:setup]) && session }
    allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(client: :client))

    Samagotchi::TerminalUI::AttachLauncher.connect(
      state_dir: state_dir, wait: 0.2, memories: ["a"], muted_memories: ["b"], llm_context: { strategy: "none" },
      thinking: "low", appended_prompt_files: ["/r/a.md"], toolkit: toolkit, settings: settings, parent_answers: "hard"
    )

    expect_cells(:attached, setups.fetch(0))
  end

  it "gives the one-shot's new session every flag it takes" do
    with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") do
      ui = Samagotchi::TerminalUI.new(client: instance_double(Samagotchi::Client), prompt: "hi", memories: ["a"],
                                      muted_memories: ["b"], llm_context: { strategy: "none" }, thinking: "low",
                                      appended_prompt_files: ["/r/a.md"], toolkit: toolkit, settings: settings,
                                      parent_answers: "hard")
      expect_cells(:one_shot, ui.new_session_setup)
    end
  end

  it "gives chi send --new every flag it takes" do
    setups = []
    allow(Samagotchi::SessionManager).to receive(:spawn_session) do |**kwargs|
      setups << kwargs[:setup]
      Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    end
    argv = ["--new", "--llm-context", "none", "--thinking", "low", "--toolkit", "lean", "--set", "recap.enabled=false",
            "--parent-answers", "hard", "-m", "hi"]
    err = StringIO.new
    expect(Samagotchi::SendCommand.new(argv, stdin: StringIO.new(""), stdout: StringIO.new, stderr: err,
                                             state_dir: state_dir).run).to eq(0), err.string

    expect_cells(:send_new, setups.fetch(0))
  end

  it "gives chi web's create every field it takes" do
    setups = []
    allow(Samagotchi::SessionManager).to receive(:spawn_session) do |**kwargs|
      setups << kwargs[:setup]
      Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    end
    app = Samagotchi::Web::App.new(manager: Samagotchi::SessionManager, state_dir: state_dir, bridge_wait_timeout: 0)
    body = { "idle" => true, "dir" => state_dir, "llm_context" => { "strategy" => "none" }, "thinking" => "low",
             "toolkit" => "lean", "settings" => { "recap.enabled" => false }, "parent_answers" => "hard" }
    env = Rack::MockRequest.env_for("/api/sessions", "HTTP_HOST" => "127.0.0.1", method: "POST",
                                                     input: JSON.generate(body))
    status, _headers, chunks = app.call(env)
    expect(status).to eq(201), chunks.to_a.join

    expect_cells(:web_create, setups.fetch(0))
  end

  it "carries every :inherited member from the session a continue, a fork and a review fork start from" do
    source = Samagotchi::Session.new_session(
      mode: "assist", model_name: "m", working_directory: Dir.pwd,
      setup: described_class.new(llm_context: Samagotchi::LLMContextOverride.new(strategy: [:stale]), thinking: :low,
                                 reasoning_history: :all, appended_prompt_files: ["/r/a.md"],
                                 preloaded_memory_names: ["a"], muted_memory_names: ["b"], toolkit: toolkit,
                                 settings: settings, parent_answers: "hard",
                                 working_set_pins: [{ "kind" => "file", "key" => "/r/a.rb" }])
    )
    { continue: described_class.of(source), plugin_fork: described_class.of(source, forked: true),
      review_fork: described_class.of(source).with(preloaded_memory_names: [], toolkit_origin: "chosen") }
      .each do |entrypoint, setup|
        described_class.members.each do |member|
          next unless SessionSetupEntrypoints.cell(entrypoint, member) == :inherited

          expect(setup.public_send(member)).to eq(source.public_send(member)), "#{entrypoint}: #{member}"
        end
      end
  end
end
