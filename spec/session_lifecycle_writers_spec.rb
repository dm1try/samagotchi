# frozen_string_literal: true

require "spec_helper"
require "prism"

module SessionLifecycleWriterCalls
  ROOT = File.expand_path("..", __dir__)
  APIS = {
    "Session.mark_stopped" => {
      "lib/samagotchi/session_manager/lifecycle.rb#stop_session" => "Marks the stop before signaling the current owner."
    },
    "Session.clear_stopped" => {
      "lib/samagotchi/session_manager/delivery.rb#start_for_send" => "A person's send can restart a stopped session.",
      "lib/samagotchi/session_manager/spawn.rb#resume" => "A successful resume clears the stop before spawning."
    },
    "StartingMarker.mark" => {
      "lib/samagotchi/session_manager/spawn.rb#spawn_session" => "Holds a new session before its file is saved.",
      "lib/samagotchi/session_manager/spawn.rb#spawn_worker_for_session" => "Holds the session while its worker starts."
    },
    "StartingMarker.claim" => {
      "lib/samagotchi/session_manager/spawn.rb#claim_start" => "Arbitrates concurrent resumes and takes over starts predating a stop."
    },
    "StartingMarker.clear" => {
      "lib/samagotchi/session_manager/spawn.rb#claim_start" => "Drops a claim when an owner already took the lock.",
      "lib/samagotchi/session_manager/spawn.rb#resume" => "Releases the start claim when spawning fails.",
      "lib/samagotchi/session_manager/spawn.rb#spawn_session" => "Releases the initial claim when setup or spawning fails.",
      "lib/samagotchi/session_manager/spawn.rb#spawn_worker_for_session" => "Clears a failed worker start.",
      "lib/samagotchi/worker.rb#start" => "The worker clears the marker after acquiring its owner lock."
    },
    "ArchiveStore.archive" => {
      "lib/samagotchi/session_manager/removal.rb#archive_session" => "Archives a session and its eligible delegate tree."
    },
    "ArchiveStore.unarchive" => {
      "lib/samagotchi/session_chain/delete.rb#delete_link" => "Restores links revived by a chain-link deletion.",
      "lib/samagotchi/session_chain/delete.rb#revive_left_end" => "Restores a previous link after an interrupted chain delete.",
      "lib/samagotchi/session_continue.rb#undo_failed_continue" => "Restores links archived by a failed continue.",
      "lib/samagotchi/session_manager/removal.rb#unarchive_session" => "Unarchives a session and its delegate tree."
    },
    "ReminderCarry.write" => {
      "lib/samagotchi/worker/leave.rb#carry_reminders" => "Hands reminders to the successor of an asked restart."
    },
    "ReminderCarry.remove" => {
      "lib/samagotchi/session_manager/lifecycle.rb#stop_session" => "A stop must not leave a restart hand-off to restore.",
      "lib/samagotchi/session_manager/removal.rb#archive_session" => "An archived link keeps no restart hand-off.",
      "lib/samagotchi/worker/leave.rb#carry_reminders" => "A stopped restart drops reminders instead of handing them off.",
      "lib/samagotchi/worker_boot.rb#respawn" => "A stop that cancels a restart drops its unused hand-off."
    },
    "ReminderCarry.take" => {
      "lib/samagotchi/worker/leave.rb#take_carried_reminders" => "The successor consumes the one-shot hand-off at startup."
    },
    "ContinueIntent.write" => {
      "lib/samagotchi/session_continue.rb#run_locked" => "Records the successor before archive and the final archived set after it."
    }
  }.freeze

  class Calls < Prism::Visitor
    attr_reader :found

    def initialize(path)
      super()
      @path = path.delete_prefix("#{ROOT}/")
      @methods = []
      @found = []
    end

    def visit_def_node(node)
      @methods << node.name
      super
    ensure
      @methods.pop
    end

    def visit_call_node(node)
      receiver = node.receiver
      api = "#{receiver.name}.#{node.name}" if receiver.is_a?(Prism::ConstantReadNode)
      if APIS.key?(api)
        @found << [api, "#{@path}##{@methods.last || "<top>"}", node.location.start_line]
      end
      super
    end
  end

  def self.calls
    paths = Dir.glob(File.join(ROOT, "lib/**/*.rb")) + Dir.glob(File.join(ROOT, "bin/*"))
    paths.sort.flat_map do |path|
      visitor = Calls.new(path)
      Prism.parse_file(path).value.accept(visitor)
      visitor.found
    end
  end
end

RSpec.describe "session lifecycle marker writers" do
  it "pins marker writer and remover call sites with reasons (docs/internals/session-lifecycle.md)" do
    actual = SessionLifecycleWriterCalls.calls
    unexpected = actual.reject do |api, callsite, _line|
      SessionLifecycleWriterCalls::APIS.fetch(api).key?(callsite)
    end
    missing = SessionLifecycleWriterCalls::APIS.flat_map do |api, callsites|
      called = actual.filter_map { |found_api, callsite, _line| callsite if found_api == api }
      callsites.keys - called.uniq
    end
    reasons = SessionLifecycleWriterCalls::APIS.values.flat_map(&:values)
    missing_reasons = reasons.select { |reason| reason.strip.empty? }

    failures = unexpected.map do |api, callsite, line|
      "#{callsite}:#{line} calls #{api}; add it to the list with a reason, see docs/internals/session-lifecycle.md"
    end
    failures.concat(missing.map { |callsite| "#{callsite} is no longer a marker writer/remover call site" })
    failures << "every allow-list entry needs a reason" unless missing_reasons.empty?

    expect(failures).to be_empty, failures.join("\n")
  end
end
