# frozen_string_literal: true

require "spec_helper"
require "prism"
require "samagotchi/turn_state"
require "samagotchi/steer_cut"
require "samagotchi/question_desk"

# The hosts hold the Engine's whole TurnState (Engine#turn_state), writers
# included; only the turn thread may call those (begin!, replace_context,
# ended!, finish!, the steers). This lists, per host file, the TurnState
# methods it may call: a new call fails here until it is added, with a
# reason that it is not a turn-thread writer.
module HostTurnStateCalls
  ROOT = File.expand_path("../..", __dir__)
  HOST_GLOBS = %w[bridge.rb bridge/*.rb worker.rb worker_*.rb worker/*.rb continue_offer.rb idle_*.rb relay_*.rb].freeze

  ALLOWED = {
    "lib/samagotchi/bridge.rb" => %i[running? controller cancel! enqueued_id? reserve_enqueued_id forget_enqueued_id
                                     drop_enqueued_id],
    "lib/samagotchi/continue_offer.rb" => %i[record_activity],
    "lib/samagotchi/idle_recap.rb" => %i[running? activity_seq last_activity_at],
    "lib/samagotchi/idle_reminders.rb" => %i[running? last_activity_at],
    "lib/samagotchi/worker.rb" => %i[running? claim_enqueued_id finish_enqueued_id],
    "lib/samagotchi/worker/command_queue.rb" => %i[running?],
    "lib/samagotchi/worker/scratch.rb" => %i[running? cancel!],
    "lib/samagotchi/worker/signal_grace.rb" => %i[running? cancel!],
    "lib/samagotchi/worker_idle_exit.rb" => %i[running? last_activity_at],
    "lib/samagotchi/worker_inbound.rb" => %i[claim_enqueued_id finish_enqueued_id]
  }.freeze

  # The turn thread's: never in ALLOWED.
  WRITERS = %i[begin! replace_context ended! finish! restart_clock! take_steers steer steer_next_turn
               drop_carried_steers own_controller input_waiting_failed!].freeze

  # The Engine's other turn parts the hosts hold whole: what any host file
  # may call on each. Not SteerCut's observe/delivered!/finished! (the turn
  # thread's) nor QuestionDesk's request/open_question (they block a request
  # thread until an answer); post/withdraw are ContinueOffer's, non-blocking.
  PARTS = {
    steer_cut: [Samagotchi::SteerCut, %i[cut_for_steer input_epoch generation_snapshot]],
    question_desk: [Samagotchi::QuestionDesk, %i[pending answer cancel annotate post withdraw]]
  }.freeze

  # Calls on @turn_state, a local turn_state, or a turn_state reader
  # (engine.turn_state.running?); the same for each of PARTS. Each found
  # call is [receiver, method, line].
  class Calls < Prism::Visitor
    RECEIVERS = [:turn_state, *PARTS.keys].freeze
    attr_reader :found

    def initialize
      super
      @found = []
    end

    def visit_call_node(node)
      receiver = node.receiver
      name = case receiver
             when Prism::InstanceVariableReadNode then receiver.name.to_s.delete_prefix("@").to_sym
             when Prism::LocalVariableReadNode, Prism::CallNode then receiver.name
             end
      @found << [name, node.name, node.location.start_line] if RECEIVERS.include?(name)
      super
    end
  end

  # @return [Array<String>] each host call on PARTS not in its allowed list
  def self.part_violations
    host_paths.flat_map do |path|
      Prism.parse_file(path).value.accept(visitor = Calls.new)
      visitor.found.filter_map do |receiver, method, line|
        next unless (allowed = PARTS.dig(receiver, 1)) && !allowed.include?(method)

        "@#{receiver}.#{method} at #{path.delete_prefix("#{ROOT}/")}:#{line}"
      end
    end
  end

  def self.host_paths = HOST_GLOBS.flat_map { |glob| Dir.glob(File.join(ROOT, "lib/samagotchi", glob)) }.sort

  # @return [Hash{String => Array<Symbol>}] each host file that calls the
  #   TurnState, and what it calls
  def self.calls_by_file
    host_paths.filter_map do |path|
      visitor = Calls.new
      Prism.parse_file(path).value.accept(visitor)
      found = visitor.found.filter_map { |receiver, method, _| method if receiver == :turn_state }.uniq
      [path.delete_prefix("#{ROOT}/"), found] unless found.empty?
    end.to_h
  end
end

RSpec.describe "Host calls on the TurnState" do
  let(:calls_by_file) { HostTurnStateCalls.calls_by_file }

  it "calls only the TurnState methods its file is allowed" do
    extra = calls_by_file.flat_map do |path, methods|
      (methods - HostTurnStateCalls::ALLOWED.fetch(path, [])).map { |method| "#{path}: #{method}" }
    end

    expect(extra).to be_empty, "TurnState calls not in HostTurnStateCalls::ALLOWED:\n#{extra.join("\n")}"
  end

  it "does not keep methods a host no longer calls" do
    stale = HostTurnStateCalls::ALLOWED.flat_map do |path, methods|
      (methods - calls_by_file.fetch(path, [])).map { |method| "#{path}: #{method}" }
    end

    expect(stale).to be_empty, "Stale entries in HostTurnStateCalls::ALLOWED:\n#{stale.join("\n")}"
  end

  it "allows no turn-thread writer, and only TurnState's own public methods" do
    allowed = HostTurnStateCalls::ALLOWED.values.flatten.uniq

    expect(allowed & HostTurnStateCalls::WRITERS).to be_empty
    expect(allowed - Samagotchi::TurnState.public_instance_methods(false)).to be_empty
    expect(HostTurnStateCalls::WRITERS - Samagotchi::TurnState.public_instance_methods(false)).to be_empty
  end
end

RSpec.describe "Host calls on the SteerCut and the QuestionDesk" do
  it "calls only each part's allowed methods" do
    extra = HostTurnStateCalls.part_violations

    expect(extra).to be_empty, "Calls not in HostTurnStateCalls::PARTS:\n#{extra.join("\n")}"
  end

  it "allows only each part's own public methods" do
    HostTurnStateCalls::PARTS.each_value do |klass, allowed|
      expect(allowed - klass.public_instance_methods(false)).to be_empty
    end
  end
end
