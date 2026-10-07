# frozen_string_literal: true

require "json"

module Samagotchi
  module Tools
    # forget_outputs, the forget layer's tool (LLMContextStrategy :forget):
    # the model forgets its own tool outputs by id, with a note that keeps
    # what it learned, or restores ones it forgot. Its schema is
    # ToolDeclarations.forget_outputs_schema; the work is LLMContextForget's,
    # on the running turn's conversation (KernelLoop#forget_outputs, through
    # the handler's kctx). This reads the call: models write lists as JSON,
    # as a JSON string, or as words, so every id form is taken.
    class ForgetOutputs
      NAME = "forget_outputs"

      def self.name = NAME

      # A call, read: the ids to forget, the note, the lines to keep
      # ({id => [[first, last], …]}), and the ids to restore.
      Request = Data.define(:ids, :note, :keep, :restore) do
        def restore? = !restore.empty?
      end

      ID = /#?\b(t\d+)\b/
      RANGE = /#?\b(t\d+)\s*[:=]\s*(?:lines?\s*)?(\d+)\s*(?:[-–]\s*(\d+))?/

      # @param call [Hash] the internal call (BuiltinCalls: ids:, note: as
      #   content:, keep:, restore:)
      # @return [Request]
      def self.parse(call)
        keep = ranges(call[:keep])
        Request.new(ids: (ids(call[:ids]) + keep.keys).uniq, note: (call[:note] || call[:content]).to_s.strip,
                    keep: keep, restore: ids(call[:restore]))
      end

      # The ids in +raw+: "t41", "#t41", a list, a JSON list, or words.
      def self.ids(raw)
        text(raw).scan(ID).flatten.uniq
      end

      # "t42:12-40" (or "t42: lines 12-40", "t42=7") entries, by id.
      def self.ranges(raw)
        text(raw).scan(RANGE).each_with_object({}) do |(id, first, last), keep|
          first = first.to_i
          last = last ? last.to_i : first
          (keep[id] ||= []) << [first, last] if first.positive? && last >= first
        end
      end

      def self.text(raw)
        case raw
        when nil then ""
        when Array then raw.map { |item| text(item) }.join(" ")
        when Hash then raw.map { |key, value| "#{key}:#{text(value)}" }.join(" ")
        else raw.to_s
        end
      end
      private_class_method :text
    end
  end
end
