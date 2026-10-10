# frozen_string_literal: true

require "json"

module Samagotchi
  # A session's analytics.json: the SessionMetrics snapshot with every turn
  # and tool record, saved next to the session file (<session dir>/
  # analytics.json). SessionMetrics#persist writes it; the session lists,
  # `chi sessions stats`, the web's timing and a collector loading an earlier
  # process's records read it. The records stay string-keyed hashes as
  # saved: their keys grow over versions and every reader treats each one
  # as optional.
  module AnalyticsFile
    NAME = "analytics.json"

    module_function

    # @param session_dir [String]
    # @return [String]
    def path(session_dir)
      File.join(session_dir, NAME)
    end

    # The parsed file, string-keyed; nil when it is missing, unreadable,
    # not JSON or not an object (an older or broken file reads as none).
    # @param session_dir [String]
    # @return [Hash, nil]
    def read(session_dir)
      data = JSON.parse(File.read(path(session_dir)))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end
  end
end
