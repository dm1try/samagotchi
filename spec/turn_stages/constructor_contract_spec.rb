# frozen_string_literal: true

require "tmpdir"
require "samagotchi/engine"
require "support/test_kernel"

# The turn stages take values, not callbacks (docs/internals/engine.md, "Turn
# stages"): what each stage's constructor takes, and the callables a built
# Engine's stages hold. What it counts: each Proc (a lambda, a proc) held in
# a stage's instance variables, and in those of an ObjectivesAudit a stage
# holds. A callable that stays is named here with its reason in the docs.
RSpec.describe "turn stages' constructor contract" do
  let(:client) { test_client }

  after { @engine&.shutdown }

  def engine
    @engine ||= Samagotchi::Engine.new(client: client, kernel: test_kernel(client: client), model_name: "Gemma-4B-it", plugins: false)
  end

  STAGES = {
    verify_anchors: Samagotchi::TurnStages::VerifyAnchors,
    toolkit_suggestion: Samagotchi::TurnStages::ToolkitSuggestion,
    context_judge: Samagotchi::TurnStages::ContextJudge,
    objectives_stage: Samagotchi::TurnStages::Objectives,
    turn_warmup: Samagotchi::TurnStages::Warmup
  }.freeze

  # Each stage's constructor keywords.
  PARAMS = {
    Samagotchi::TurnStages::VerifyAnchors => [],
    Samagotchi::TurnStages::ToolkitSuggestion => %i[side_judgments host_registry toolkit_binding tools],
    Samagotchi::TurnStages::ContextJudge => %i[side_judgments host_registry turn_state show_card current_session],
    Samagotchi::TurnStages::Objectives => %i[side_judgments host_registry],
    Samagotchi::TurnStages::Warmup => %i[prompt_warmup kernel turn_state model_settings model system_prompt reminders_due next_turn_waiting]
  }.freeze

  # The callables a built Engine's stages hold, as "Stage#@ivar".
  HELD = %w[
    ContextJudge#@show_card ContextJudge#@current_session
    Warmup#@model Warmup#@system_prompt Warmup#@reminders_due Warmup#@next_turn_waiting
  ].freeze

  def held_procs(object)
    object.instance_variables.flat_map do |ivar|
      value = object.instance_variable_get(ivar)
      if value.is_a?(Proc)
        ["#{object.class.name.split("::").last}##{ivar}"]
      elsif value.is_a?(Samagotchi::ObjectivesAudit)
        held_procs(value)
      else
        []
      end
    end
  end

  it "takes these constructor keywords" do
    PARAMS.each do |stage, params|
      expect(stage.instance_method(:initialize).parameters.map(&:last)).to eq(params), stage.name
    end
  end

  it "holds only the callables listed (#{HELD.size})" do
    held = STAGES.keys.flat_map { |reader| held_procs(engine.send(reader)) }

    expect(held).to match_array(HELD)
  end
end
