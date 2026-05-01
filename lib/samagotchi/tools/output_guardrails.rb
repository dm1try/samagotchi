# frozen_string_literal: true

module Samagotchi
  module Tools
    # Shared output-guardrail helpers used by tools that can return large payloads.
    module OutputGuardrails
      DEFAULT_TRUNCATE_AT_BYTES = 64 * 1024
      DEFAULT_PREVIEW_BYTES = 12 * 1024
      DEFAULT_TELEMETRY_THRESHOLD_PCT = 80.0
      DEFAULT_CONTEXT_WINDOW_TOKENS = 256_000
      DEFAULT_CHARS_PER_TOKEN = 4.0

      module_function

      def env_positive_int(key, default)
        value = ENV.fetch(key, default.to_s).to_i
        value.positive? ? value : default
      end

      def env_positive_float(key, default)
        value = ENV.fetch(key, default.to_s).to_f
        value.positive? ? value : default
      end

      def safe_utf8(bytes)
        bytes.to_s
             .force_encoding(Encoding::UTF_8)
             .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
      end

      def head_tail_from_file(path:, file_size:, preview_bytes:)
        half = [preview_bytes / 2, 1].max
        head = File.binread(path, half, 0)
        tail_offset = [file_size - half, 0].max
        tail = File.binread(path, [half, file_size].min, tail_offset)

        build_preview_parts(head: head, tail: tail, total_bytes: file_size)
      end

      def head_tail_from_string(content:, preview_bytes:)
        half = [preview_bytes / 2, 1].max
        head = content.byteslice(0, half) || ""
        tail = content.byteslice(-half, half) || ""

        build_preview_parts(head: head, tail: tail, total_bytes: content.bytesize)
      end

      def telemetry_lines_for(content:, threshold_env:, threshold_default:, token_key:, pct_key:)
        chars_per_token = env_positive_float("SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN", DEFAULT_CHARS_PER_TOKEN)
        window_tokens = env_positive_int("SAMAGOTCHI_CONTEXT_WINDOW_TOKENS", DEFAULT_CONTEXT_WINDOW_TOKENS)
        telemetry_threshold_pct = env_positive_float(threshold_env, threshold_default)

        estimated_tokens = (content.length / chars_per_token).ceil
        estimated_window_pct = (estimated_tokens.to_f / window_tokens) * 100.0
        return [] if estimated_window_pct < telemetry_threshold_pct

        [
          "#{token_key}=#{estimated_tokens}",
          format("#{pct_key}=%.2f", estimated_window_pct)
        ]
      end

      def build_preview_parts(head:, tail:, total_bytes:)
        head_bytes = head.bytesize
        tail_bytes = tail.bytesize
        omitted_bytes = [total_bytes - (head_bytes + tail_bytes), 0].max

        {
          head: safe_utf8(head),
          tail: safe_utf8(tail),
          head_bytes: head_bytes,
          tail_bytes: tail_bytes,
          returned_preview_bytes: head_bytes + tail_bytes,
          omitted_bytes: omitted_bytes,
          total_bytes: total_bytes
        }
      end
      private_class_method :build_preview_parts
    end
  end
end
