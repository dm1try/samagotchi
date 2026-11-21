# frozen_string_literal: true

require_relative "../block_fix"
require_relative "../block_renderers"

module Samagotchi
  class Bridge
    # POST /session/:id/blocks/fix {turn_id, lang, source, reason}: a block
    # the page couldn't draw in the newest answer, asked for again once
    # (Engine#fix_block; docs/internals/block-renderers.md, A failed block is
    # asked for again). Mixed into Bridge (#parse_json, #fetched, @engine).
    module BlockFixRoute
      # 400 missing_fields without a turn id, a language a fence can name or
      # a source; else Engine#fix_block's status and body.
      # @return [Array(Hash, Integer, Hash)]
      def handle_block_fix(_session_id, body)
        parsed = parse_json(body)
        return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }] unless parsed.is_a?(Hash)

        turn_id, lang, source, reason = %w[turn_id lang source reason].map { |key| fetched(parsed, key) }
        unless [turn_id, lang, source].all? { |v| v.is_a?(String) && !v.empty? } && lang.match?(BlockRenderers::LANG)
          return [{ "Allow" => "POST" }, 400, { error: "missing_fields", detail: "turn_id, lang and source required" }]
        end

        status, answer = @engine.fix_block(turn_id: turn_id, lang: lang, source: source, reason: reason.to_s)
        [{}, status, answer]
      end
    end
  end
end
