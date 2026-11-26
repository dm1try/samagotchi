# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "samagotchi/archive_store"
require "samagotchi/schedules"
require "samagotchi/session"

# A schedule's chain after a prune took the anchor's successor, on disk:
# A (the anchor, archived) → B (deleted) → C (archived) → D (live, the
# schedule's head), with the schedule entry in schedules.json beside the
# sessions dir. +state_dir+ must be a sessions dir under a root of its own
# (the schedules file lives in its parent).
module PrunedAnchor
  Chain = Data.define(:anchor, :gone, :middle, :head, :schedule_id)

  def pruned_anchor_chain(state_dir)
    save = lambda do |continues|
      Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.tmpdir,
                                      continues: continues).tap { |s| s.save(state_dir: state_dir) }
    end
    anchor = save.call(nil)
    gone = save.call(anchor.id)
    middle = save.call(gone.id)
    head = save.call(middle.id)
    [anchor, gone, middle].each { |s| Samagotchi::ArchiveStore.archive(s.id, state_dir: state_dir) }
    entry = Samagotchi::Schedules.new(state_dir: state_dir)
                                 .add(target: anchor.id, prompt: "Audit", recurrence: Samagotchi::Schedules.recurrence(every: "1h"))
    point_head(state_dir, entry.id, head.id)
    FileUtils.rm_f(Samagotchi::Session.session_file(gone.id, state_dir: state_dir))
    FileUtils.rm_rf(Samagotchi::Session.session_dir(gone.id, state_dir: state_dir))
    Chain.new(anchor: anchor.id, gone: gone.id, middle: middle.id, head: head.id, schedule_id: entry.id)
  end

  # The entry's head as a firing writes it (re-anchored on its new link).
  def point_head(state_dir, schedule_id, head)
    schedules = Samagotchi::Schedules.new(state_dir: state_dir)
    doc = JSON.parse(File.read(schedules.path))
    doc.fetch("schedules").find { |raw| raw["id"] == schedule_id }["head"] = head
    File.write(schedules.path, JSON.generate(doc))
  end
end
