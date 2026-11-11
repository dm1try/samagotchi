# frozen_string_literal: true

require "securerandom"

require_relative "answer_text"
require_relative "context_note"
require_relative "llm_context_stale"
require_relative "redact"
require_relative "steer"

module Samagotchi
  autoload :Objectives, File.expand_path("objectives", __dir__)

  # The session's record as a side reader of the objectives sees it (Check
  # this, ObjectivesCheck; the tracker, ObjectivesTrack): what people and notes
  # said, what the tools returned, and what the agent said to the user,
  # labelled OWN_WORDS (it settles what was said, not what was done), oldest
  # first, its tail when long. Never the agent's thinking, nor the objectives
  # tool's own calls (a move isn't evidence for itself), nor the list's notes.
  # Also the random-tag frame the record goes in and the redaction of what is
  # sent: a reader's model may be another host's. See
  # docs/internals/objectives.md (Check this, Independence).
  module ObjectivesRecord
    # The record's size in a request, its tail kept, and each entry's.
    RECORD_CHARS = 24_000
    OUTPUT_CHARS = 1_500
    LEFT_OUT = "[earlier record left out]"
    # What the agent said to the user, in the record.
    OWN_WORDS = "[agent's own words]"

    module_function

    # @return [String]
    def record(conversation)
      conversation = Array(conversation)
      runs = LLMContextStale.paired_runs(conversation).group_by(&:index)
      parts = conversation.each_with_index.flat_map do |entry, index|
        runs.key?(index) ? runs[index].filter_map { |run| run_part(run) } : Array(said_part(entry))
      end
      tail_of(parts)
    end

    # A frame tag no text in the record could know, made per request, so tool
    # output printing a closing tag stays inside.
    def tag = "record-#{SecureRandom.hex(8)}"

    # +body+ between +tag+'s opening and closing lines.
    def framed(tag, body) = "<#{tag}>\n#{body}\n</#{tag}>"

    # Secrets chi's participant redaction knows (Redact, by shape and by name,
    # no model involved) taken out of +text+.
    def redacted(text)
      Redact.text(text, Redact::Viewer.new(cwd: nil))
    end

    # +text+ at most +max+ characters: its head and tail around an ellipsis.
    def cut(text, max)
      text = text.to_s.scrub
      text.length > max ? "#{text[0, max / 2]}\n…\n#{text[(-max / 2)..]}" : text
    end

    def run_part(run)
      name = run.call[:name].to_s
      return nil if name == "objectives"

      args = run.call.except(:name).reject { |_key, value| value.to_s.empty? }.map { |key, value| "#{key}=#{value}" }.join(" ")
      "[tool #{name} #{cut(args, 300)}]\n#{cut(run.text, OUTPUT_CHARS)}"
    end
    private_class_method :run_part

    def said_part(entry)
      text = text_of(entry[:content] || entry["content"])
      return nil if text.strip.empty?

      case (entry[:role] || entry["role"]).to_s
      when "model"
        words = AnswerText.visible(text)
        "#{OWN_WORDS}\n#{cut(words, OUTPUT_CHARS)}" unless words.empty?
      when "user" then "[#{Steer.participant_message?(entry) ? "participant" : "user"}]\n#{cut(text, OUTPUT_CHARS)}"
      when "system"
        return nil unless ContextNote.note?(entry) &&
                          Objectives.outside_note?(ContextNote.fetch(entry, :source), ContextNote.fetch(entry, :objectives))

        "[note]\n#{cut(text, OUTPUT_CHARS)}"
      end
    end
    private_class_method :said_part

    # A multipart entry's text parts.
    def text_of(content)
      return content.to_s.scrub if content.is_a?(String)

      Array(content).filter_map { |part| part[:text] || part["text"] if part.is_a?(Hash) }.join("\n").scrub
    end
    private_class_method :text_of

    def tail_of(parts)
      room = RECORD_CHARS
      kept = parts.reverse_each.take_while { |part| (room -= part.length + 2) >= 0 }.reverse
      kept.size < parts.size ? [LEFT_OUT, *kept].join("\n\n") : kept.join("\n\n")
    end
    private_class_method :tail_of
  end
end
