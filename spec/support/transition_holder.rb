# frozen_string_literal: true

require "fileutils"
require "samagotchi/continue_intent"
require "samagotchi/session"
require "samagotchi/session_transition"

# A transition of session +id+ in flight while the block runs: its lock
# held exclusively by another thread (never the spec's own: a thread that
# holds it passes through its own shared holds), and, with +successor+, a
# continue's: its intent naming it first and the successor's lock held too
# (ContinueIntent.in_flight reads all three). +kind+ is what the holder
# records (SessionTransition.holder): a continue's with +successor+, none
# by default (Busy's plain words), :delete for a delete's.
#
#   holding_transition(id, state_dir: dir, successor: new_id) { access.peer_say(...) }
module TransitionHolder
  def holding_transition(id, state_dir:, successor: nil, kind: successor ? :continue : nil)
    folder = FileUtils.mkdir_p(Samagotchi::Session.session_dir(id, state_dir: state_dir)).first
    if successor
      Samagotchi::ContinueIntent.write(File.join(folder, Samagotchi::ContinueIntent::FILE), successor_id: successor,
                                                                                            previously_archived: [])
    end
    taken = Queue.new
    release = Queue.new
    holder = Thread.new do
      Samagotchi::SessionTransition.exclusive([id, successor].compact, kind: kind, state_dir: state_dir) do
        taken << true
        release.pop
      end
    end
    taken.pop(timeout: 10) or raise "the transition lock of #{id} was not taken"
    yield
  ensure
    release&.push(true)
    holder&.join
  end
end
