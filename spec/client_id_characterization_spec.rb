# frozen_string_literal: true

require "samagotchi/client_id"
require "samagotchi/steer"

# What each sender id gets from the six questions ClientId and Steer
# answer about it: human?, owner?, interactive?, wake_kind, origin and
# Steer.source_for_client. Every constant, a sample id per prefix, nil, ""
# and ids chi doesn't know. Pinned before the sender rows replaced the
# six tables (the plan's characterization), and kept: a row change must
# show up here.
RSpec.describe "ClientId: what each sender gets" do
  ids = Samagotchi::ClientId
  # [human?, owner?, interactive?, wake_kind, origin, source]
  web = [true, true, true, :send, "client", nil]
  automatic = ->(origin = "client", wake = :automatic) { [false, false, false, wake, origin, :automatic] }
  expected = {
    nil => [true, false, false, :automatic, "client", nil],
    "" => automatic.call,
    "web:ab12cd34" => web,
    ids::WEB_PREFIX => web,
    ids::WEB_RESTART => web,
    ids::WEB_CREATE => web,
    ids::WEB_UNNAMED => web,
    "tui:4242" => web,
    ids::TUI_PREFIX => web,
    ids::CLI_SEND => [true, true, false, :send, "client", "chi_send"],
    ids::CLI_ANSWER => automatic.call,
    ids::CLI_RESTART => automatic.call,
    "delegate:1234abcd" => [false, false, false, :delegate, "delegate", "parent_agent"],
    "child:1234abcd" => [false, false, false, :automatic, "delegate_report", "delegate_report"],
    "context:pr-123" => automatic.call("context"),
    "task:3f9a2c1d" => automatic.call("task"),
    "system:other" => automatic.call,
    ids::REMINDER => automatic.call("reminder"),
    "system:schedule:1234abcd" => automatic.call("schedule", :schedule),
    ids::PLUGIN => [false, false, false, :plugin, "client", "plugin_send"],
    "relay:1234abcd" => automatic.call,
    "review:p_0123abcd" => [true, false, false, :participant, "review", "participant"],
    "other:1" => automatic.call,
    "webby" => automatic.call,
    "web" => automatic.call,
    "plugin:x" => automatic.call,
    "cli:other" => automatic.call
  }

  expected.each do |id, (human, owner, interactive, wake, origin, source)|
    it "answers for #{id.inspect}" do
      source = "#{Samagotchi::Steer::AUTOMATIC_SOURCE_PREFIX}#{id}" if source == :automatic
      got = [ids.human?(id), ids.owner?(id), ids.interactive?(id), ids.wake_kind(id), ids.origin(id),
             Samagotchi::Steer.source_for_client(id)]
      expect(got).to eq([human, owner, interactive, wake, origin, source])
    end
  end
end
