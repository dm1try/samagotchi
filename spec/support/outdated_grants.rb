# frozen_string_literal: true

require "json"
require "samagotchi/grants"
require "samagotchi/participants"
require "samagotchi/session"

# A grant as an older chi issued it for read-only (review) turns: no
# "mode" in grants.json nor in its session's participants.json. This chi
# reads it as ended (Grants::Grant#state :outdated) and refuses the
# participant's turns (WorkerParticipantGate#refusal "outdated").
module OutdatedGrants
  # @param grants [Samagotchi::Grants]
  # @param grant [Samagotchi::Grants::Grant]
  # @return [Samagotchi::Grants::Grant] the grant as the store now reads it
  def make_outdated!(grants, grant, state_dir:)
    store = JSON.parse(File.read(grants.path))
    store["grants"].each { |row| row.delete("mode") if row["id"] == grant.id }
    File.write(grants.path, JSON.generate(store))
    sidecar = File.join(Samagotchi::Session.session_dir(grant.session_id, state_dir: state_dir), Samagotchi::Participants::FILE)
    if File.exist?(sidecar)
      data = JSON.parse(File.read(sidecar))
      data["participants"].each { |row| row.delete("mode") if row["id"] == grant.id }
      File.write(sidecar, JSON.generate(data))
    end
    grants.find(grant.id)
  end
end
