# frozen_string_literal: true

require "time"
require_relative "../memory_bundle/index_size"

module Samagotchi
  class TerminalUI
    # A session's rows per model in /stats (the snapshot's model_segments).
    # The four public model_segment_* labels are the words the web's ctx
    # tooltip shares (ctx.js; spec/shared/labels_matrix.json model_segments).
    # Rows come symbol- or string-keyed (the attached TUI's as JSON).
    # Included by Formatting, whose cost_text and speed_text it uses.
    module ModelSegmentsText
      # A row's model: its ref; the rows folded past the cap ("3 earlier
      # segments", told by folded_segments); a session's turns from before
      # turns named their model ("earlier turns").
      def model_segment_label(row)
        folded = segment_value(row, :folded_segments).to_i
        return "#{folded} earlier segments" if folded.positive?

        ref = segment_value(row, :model_ref).to_s
        ref.empty? ? "earlier turns" : ref
      end

      # "6.0k in / 40 out": the row's prompt and completion sums.
      def model_segment_tokens_text(row)
        count = ->(key) { MemoryBundle::IndexSize.count_text(segment_value(row, key).to_i) }
        "#{count.call(:prompt_sum)} in / #{count.call(:completion_sum)} out"
      end

      # "$0.42", "~$0.12", "$0.42 + ~$0.12" (reported + estimated); "" for none.
      def model_segment_cost_text(row)
        [cost_text(segment_value(row, :cost_sum)), cost_text(segment_value(row, :cost_estimate_sum), estimate: true)]
          .reject(&:empty?).join(" + ")
      end

      # "switch prefill 3.0k uncached prompt ≈$0.0060": what the switch to the
      # row's model prefilled (its cost an estimate from the configured
      # price, left out without one); "" for none.
      def model_segment_prefill_text(row)
        tokens = segment_value(row, :prefill_tokens).to_i
        return "" unless tokens.positive?

        cost = cost_text(segment_value(row, :prefill_cost_estimate))
        "switch prefill #{MemoryBundle::IndexSize.count_text(tokens)} uncached prompt#{" ≈#{cost}" unless cost.empty?}"
      end

      private

      def segment_value(row, key)
        row[key] || row[key.to_s]
      end

      # /stats' models: block, in place of the tokens line: a row per
      # segment (model, when, turns, tokens, its average speed and cost), a
      # switch's prefill under the row of the model switched to, and the
      # total (the tokens line's sums and breakdown).
      def models_block_lines(segments, turns, tokens, token_src_label)
        dated = segment_dates_differ?(segments)
        cells = segments.map do |row|
          speed = speed_text(segment_value(row, :avg_decode_tps), segment_value(row, :tps_source))
          [model_segment_label(row), segment_span_text(row, dated: dated), turns_text(segment_value(row, :turns)),
           [model_segment_tokens_text(row), speed, model_segment_cost_text(row)].reject(&:empty?).join("  ")]
        end
        total = ["total", "", turns_text(turns),
                 "#{MemoryBundle::IndexSize.count_text(tokens[:prompt_sum].to_i)} in / " \
                 "#{MemoryBundle::IndexSize.count_text(tokens[:completion_sum].to_i)} out " \
                 "(all requests, #{token_src_label}#{token_breakdown_text(tokens)})"]
        widths = (0..2).map { |i| (cells + [total]).map { |cell| cell[i].length }.max }
        row_text = ->(cell) { cell.each_with_index.map { |text, i| i < 3 ? text.ljust(widths[i]) : text }.join("  ") }
        lines = []
        segments.each_with_index do |row, i|
          lines << "#{i.zero? ? "models:".ljust(18) : " " * 18}#{row_text.call(cells[i])}"
          prefill = model_segment_prefill_text(row)
          lines << "#{" " * 20}└ #{prefill}" unless prefill.empty?
        end
        lines << "#{" " * 18}#{row_text.call(total)}"
      end

      def turns_text(count)
        "#{count.to_i} #{count.to_i == 1 ? "turn" : "turns"}"
      end

      # "10:02–10:41", "10:43–now" (a row with a turn running); with the
      # day ("Oct 16 10:02") when the rows span more than one day.
      def segment_span_text(row, dated:)
        started = segment_time(segment_value(row, :started_at))
        ended = segment_time(segment_value(row, :ended_at))
        format_time = lambda { |time|
          if time
            time.strftime(dated ? "%b %-d %H:%M" : "%H:%M")
          else
            "?"
          end
        }
        "#{format_time.call(started)}–#{ended ? format_time.call(ended) : "now"}"
      end

      def segment_dates_differ?(segments)
        days = segments.flat_map { |row| [segment_value(row, :started_at), segment_value(row, :ended_at)] }
                       .filter_map { |stamp| segment_time(stamp)&.strftime("%F") }
        days.uniq.size > 1
      end

      def segment_time(stamp)
        stamp ? Time.iso8601(stamp.to_s).localtime : nil
      rescue ArgumentError
        nil
      end

      # The row the session's last speed came from: the newest with one.
      def last_speed_label(segments)
        row = segments.reverse_each.find { |segment| segment_value(segment, :last_decode_tps) }
        row && model_segment_label(row)
      end
    end
  end
end
