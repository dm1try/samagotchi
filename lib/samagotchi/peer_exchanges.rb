# frozen_string_literal: true

require_relative "context_absorber"
require_relative "jsonl_store"
require_relative "session"

module Samagotchi
  # A session's peer exchange metadata, append-only and uncapped. No answer
  # text is stored; readers join the log and return only the requested tail.
  module PeerExchanges
    FILE = "peer_exchanges.jsonl"
    STORE = JsonlStore.new(FILE)

    module_function

    def append(session_id, entry, state_dir:)
      STORE.write(Session.session_dir(session_id, state_dir: state_dir), **entry)
    end

    def read(session_id, state_dir:)
      STORE.lines(Session.session_dir(session_id, state_dir: state_dir))
    end

    # Process in timestamp order, breaking equal timestamps by append order.
    # Failed sends cannot claim an answer. One answer can claim a send; any
    # further answers remain visible as unclaimed.
    def joined(entries, last: 20)
      rows = []
      entries.each_with_index.sort_by { |entry, index| [JsonlStore.time_of(entry), index] }.each do |entry, index|
        case entry["t"]
        when "sent", "send_failed"
          rows << [send_row(entry), index]
        when "answer"
          answer = answer_row(entry)
          send = matching_send(rows, entry)
          if send
            send[:state] = "answered"
            send[:answer] = answer
          else
            rows << [{ id: nil, at: entry["at"], state: "answered", answer: answer }, index]
          end
        end
      end
      rows.sort_by { |row, index| [JsonlStore.time_of("at" => row[:at]), index] }.last(last).reverse.map(&:first)
    end

    def send_row(entry)
      state = if entry["t"] == "send_failed" then "failed"
              elsif entry["kind"] == "context" then "none_expected"
              else "waiting"
              end
      { id: entry["id"], kind: entry["kind"], title: entry["title"], by: entry["by"], at: entry["at"],
        state: state, error: entry["error"] }.compact
    end

    def matching_send(rows, entry)
      rows.reverse_each do |row, _index|
        if entry["re"] && row[:id] == entry["re"] && row[:state] != "failed"
          return row if %w[waiting none_expected].include?(row[:state])

          return nil
        end
        next unless %w[waiting none_expected].include?(row[:state])

        return row if !entry["re"] && row[:state] == "waiting" && %w[validate question].include?(row[:kind])
      end
      nil
    end

    def answer_row(entry)
      verdict = entry["summary"].to_s.scan(ContextAbsorber::VERDICT).last&.first
      { summary: entry["summary"], at: entry["at"], serial: entry["serial"],
        verdict: (verdict if ContextAbsorber::VERDICTS.include?(verdict)) }.compact
    end
  end
end
