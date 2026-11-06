# frozen_string_literal: true

module Samagotchi
  module Objectives
    # One /objectives edit line against a list, pure: what ObjectivesCommand
    # applies and what a proposal (Proposal#refusal) is checked with, so the
    # objectives tool refuses exactly what its card's Apply would. Reads the
    # Objectives constants at a call, so objectives.rb can load it first.
    module Edit
      SEPARATOR = /\n|(?:\A|\s)\|(?:\s|\z)/

      module_function

      # What the frame shows a status as: typed at a text's start it would pass
      # for one (Item#line).
      def status_mark = /\A(?:\[(?:#{Objectives::STATUSES.join("|")})\]\s*)+/i

      # The verbs that set a status, and the status each sets.
      def marks = { "done" => Objectives::DONE, "drop" => Objectives::DROPPED, "undo" => Objectives::ACTIVE }

      # @param verb [String] set, add, edit, done, drop or undo, lower case
      # @param rest [String] what follows it
      # @param was [String, nil] what a reword was proposed against (Objectives.fingerprint)
      # @return [List, String, nil] the new list, what's wrong with the line,
      #   or nil for a line that isn't one
      def apply(list, verb, rest, was: nil)
        case verb
        when "set", "add"
          entries = entries_of(rest)
          return nil if entries.nil? || entries.empty?

          verb == "set" ? list.set(entries) : entries.reduce(list) { |so_far, e| so_far.add(e[:text], done_when: e[:done_when]) }
        when "edit" then reword(list, rest, was: was)
        when *marks.keys then mark(list, marks.fetch(verb), rest)
        end
      end

      def mark(list, status, rest)
        ids = rest.upcase.split(/[\s,]+/).reject(&:empty?)
        return nil if ids.empty?

        missing = ids.reject { |id| list.find(id) }
        return Objectives.unknown(missing, list) unless missing.empty?

        if status == Objectives::DONE
          dropped = ids.select { |id| list.find(id).status == Objectives::DROPPED }
          return Objectives.dropped(dropped) unless dropped.empty?
        end

        ids.reduce(list) { |so_far, id| so_far.mark(id, status) }
      end

      # The objective's new text: the whole rest of the line, a | too.
      def reword(list, rest, was: nil)
        id, text = rest.strip.split(/\s+/, 2)
        entry = text && entry_of(text.gsub(/[[:space:]]+/, " ").strip)
        return nil unless entry

        id = id.upcase
        item = list.find(id) or return Objectives.unknown(id, list)
        return "#{id} has changed since this was proposed: #{item.text}" if was && Objectives.fingerprint(item) != was

        list.reword(id, entry[:text], done_when: entry[:done_when])
      end

      # One {text:, done_when:} per line or |-part, any whitespace collapsed
      # (Unicode line separators too: the frame is one line per item).
      # @return [Array<Hash>, nil] nil when a part has no text of its own
      def entries_of(rest)
        parts = rest.split(SEPARATOR).map { |part| part.gsub(/[[:space:]]+/, " ").strip }.reject(&:empty?)
        entries = parts.map { |part| entry_of(part) }
        entries.all? ? entries : nil
      end

      # A part's text and done-when, nil when it has no text of its own (only a
      # done-when, or only status marks). A leading status mark is stripped.
      def entry_of(part)
        found = Objectives::DONE_WHEN.match(part)
        text = (found ? found[1] : part).sub(status_mark, "").strip
        return nil if text.empty?

        done_when = found && found[2]
        { text: text, done_when: done_when.to_s.empty? ? nil : done_when }
      end
    end
  end
end
