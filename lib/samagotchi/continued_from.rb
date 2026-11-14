# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "atomic_file"
require_relative "session"

module Samagotchi
  # <link>/continued_from.json: what the continue that made this link did to
  # the previous one, so deleting the link can undo it (SessionChain::Delete,
  # D5): the previous link's id, the ids the continue archived (it and the
  # delegates archived with it, not the ones archived before) and the
  # delegates it moved here. Written in the new link's before_spawn, before
  # the carry (SessionContinue.spawn_continuation), and never changed. A
  # link an older chi made has none: the delete falls back to the previous
  # link alone and its children whose parent.json says they came from it.
  # CROSS-VERSION: another chi's delete reads this file
  # (spec/compat/readers_spec.rb).
  module ContinuedFrom
    FILE = "continued_from.json"

    Record = Data.define(:previous_id, :archived_ids, :moved_ids)

    module_function

    def path(id, state_dir:) = File.join(Session.session_dir(id, state_dir: state_dir), FILE)

    # @param archived_ids [Array<String>]
    # @param moved_ids [Array<String>]
    def write(id, previous_id:, archived_ids:, moved_ids:, state_dir:)
      file = path(id, state_dir: state_dir)
      FileUtils.mkdir_p(File.dirname(file))
      data = { previous_id: previous_id, archived_ids: archived_ids, moved_ids: moved_ids }
      AtomicFile.write(file, "#{JSON.generate(data)}\n", perm: 0o600)
    end

    # The record, nil when there is none (an older chi's link) or it doesn't
    # read as one (no valid previous id). Ids that aren't ids are dropped.
    # @return [Record, nil]
    def read(id, state_dir:)
      data = JSON.parse(File.read(path(id, state_dir: state_dir)))
      return nil unless data.is_a?(Hash) && Session.valid_id?(data["previous_id"])

      Record.new(previous_id: data["previous_id"], archived_ids: ids(data["archived_ids"]), moved_ids: ids(data["moved_ids"]))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def ids(value) = Array(value).select { |id| Session.valid_id?(id) }
  end
end
