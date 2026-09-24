# frozen_string_literal: true

require_relative "../served_model"
require_relative "../image_store"

module Samagotchi
  class TerminalUI
    # Line formatting shared by the REPL and the attached view: colour, the
    # `tool>` line, elapsed durations. Pure apart from reading whether
    # $stdout is a colour terminal.
    module Formatting
      def format_tool_activity_line(activity, duration_ms: nil)
        params = activity[:params].to_s.strip
        params_suffix = params.empty? ? "" : " #{paint(params, 90)}"
        status = activity[:status].to_s
        status_color = status == "ok" ? 32 : 31
        elapsed_suffix = duration_ms.nil? ? "" : " (#{format_elapsed_duration(duration_ms)})"
        "#{paint('tool>', 36)} #{activity[:action]} (#{activity[:tool]}#{params_suffix}): #{paint(status, status_color)}#{elapsed_suffix}"
      end

      # "[image shot.png 1280×800 · ~1.3k tokens]", dim: a turn's image.
      def format_image_line(ref)
        paint("[image #{ImageRef.label(ImageStore.symbolize(ref))}]", 90)
      end

      # " → image 1280×800" after a tool line whose tool read an image.
      def format_tool_image_suffix(images)
        refs = Array(images).map { |ref| ImageStore.symbolize(ref) }
        return "" if refs.empty?

        " #{paint(refs.map { |ref| "→ image #{ref[:width]}×#{ref[:height]}" }.join(", "), 90)}"
      end

      private

      # What /recap says (the REPL's words, attached mode's too).
      # @param recap [String, nil] the latest recap
      # @param stale [Boolean] the conversation moved on since it
      def recap_command_text(enabled:, recap:, stale: false, min_user_turns: nil, inactivity_seconds: nil)
        unless enabled
          return "recap is off (recap: false in config.yml, or SAMAGOTCHI_RECAP_ENABLED=false)"
        end
        return "session recap#{' (from before your latest turn)' if stale}:\n#{recap}" if recap

        "no recap available yet — the session needs at least #{min_user_turns} user turns and " \
          "#{inactivity_seconds}s of inactivity to generate one automatically"
      end

      # ── The status line (the REPL's, and attached mode's idle one) ────────

      # SAMAGOTCHI_STATUS_LINE=off hides it.
      def status_line_enabled?
        value = ENV.fetch(STATUS_LINE_ENV, STATUS_LINE_ON).to_s.strip.downcase
        !(value.empty? || value == STATUS_LINE_OFF || value == "0" || value == "false")
      end

      # @return [Array<String>] the "status> a | b" row, cut to +width+
      def status_rows(segments, width)
        return [] if segments.empty? || width <= 0

        row = cap_preview_text("status> #{segments.join(' | ')}", width)
        [color_output? ? paint(row, 90) : row]
      end

      # Longest asked-for name the status line keeps next to a served one.
      STATUS_ASKED_MAX = 24

      # +served+ / +served_for+: the model the server said it served for the
      # name asked (see Engine#served_model); shown first when it's another
      # model.
      def status_model_text(model, default_model, served: nil, served_for: nil)
        if ServedModel.differs?(served_for, served)
          asked = model.to_s.length > STATUS_ASKED_MAX ? "#{model.to_s[0, STATUS_ASKED_MAX - 1]}…" : model
          return "model=#{served} (served; asked #{asked})"
        end
        return "model=#{model}" if default_model.nil? || model == default_model

        "model=#{model} (default: #{default_model})"
      end

      # @param server [Hash, nil] the server's own numbers ({ctx_pct:, prompt_tokens:, ...})
      # @param estimate [Hash, nil] the kernel's estimate ({est_pct:, bucket:})
      def status_context_text(server: nil, estimate: nil)
        return format_server_context_segment(server) if server.is_a?(Hash)
        return "" unless estimate.is_a?(Hash)

        pct = format("%.1f", estimate[:est_pct].to_f)
        bucket = estimate[:bucket].to_s
        return "ctx=#{pct}%" if bucket.empty?

        "ctx=#{pct}% (#{bucket})"
      end

      def format_server_context_segment(status)
        pct = status[:ctx_pct]
        base = pct ? "ctx=#{format('%.1f', pct)}%" : "ctx=srv"

        tokens = []
        prompt_tokens = status[:prompt_tokens]
        completion_tokens = status[:completion_tokens]
        total_tokens = status[:total_tokens]
        tokens << "p=#{prompt_tokens}" if prompt_tokens
        tokens << "c=#{completion_tokens}" if completion_tokens
        tokens << "t=#{total_tokens}" if total_tokens

        return base if tokens.empty?

        "#{base} (#{tokens.join(' ')})"
      end

      def status_memory_text(names, limit)
        names = Array(names)
        return "" if names.empty?

        visible = names.first(limit)
        suffix = names.length > visible.length ? ", +#{names.length - visible.length}" : ""
        "mem: #{visible.join(', ')}#{suffix}"
      end

      def cap_preview_text(text, width)
        return "" if width <= 0

        value = text.to_s
        value.length > width ? value[0, width] : value
      end

      # Render the analytics snapshot as a compact, user-facing report. Raw event
      # logs (debug-only) are intentionally excluded; this surface is for the REPL.
      def format_session_metrics(snapshot)
        return "(no metrics yet)" unless snapshot.is_a?(Hash)

        # A symbol locally; a string when the snapshot came over the Bridge.
        token_src = snapshot[:token_source]&.to_s
        token_src_label = case token_src
                          when "server" then "server-reported"
                          when "estimate" then "estimated (chars/4)"
                          else "n/a"
                          end

        lines = []
        lines << "turns:            #{snapshot[:turns]}"
        lines << "tool calls:       #{snapshot[:tool_calls_total]} (#{snapshot[:tool_errors]} errors)"
        unless snapshot[:tool_calls_by_tool].to_a.empty?
          by_tool = snapshot[:tool_calls_by_tool].sort_by { |_k, v| -v }
          lines << "  by tool:        #{by_tool.map { |k, v| "#{k}=#{v}" }.join(", ")}"
        end
        lines << "iterations:       #{snapshot[:iterations_total]}"
        lines << "tokens in/out:    #{snapshot[:tokens_in]}/#{snapshot[:tokens_out]} (total #{snapshot[:tokens_total]}, #{token_src_label})"
        lines << "gen latency (ms): #{snapshot[:gen_latency_ms]}"
        lines << "cancellations:    #{snapshot[:cancellations]}"
        lines << "retries:          #{snapshot[:retries]}"
        if snapshot[:context_window_tokens]
          lines << "context window:   #{snapshot[:context_window_tokens]} tokens (#{snapshot[:context_window_source]})"
        end
        lines << "prompt profile:   #{snapshot[:profile]} (#{snapshot[:profile_source]})" if snapshot[:profile]
        if snapshot[:served_model]
          asked = snapshot[:served_model_for]
          note = ServedModel.differs?(asked, snapshot[:served_model]) ? " (asked for #{asked})" : ""
          lines << "served model:     #{snapshot[:served_model]}#{note}"
        end
        lines.join("\n")
      end

      def format_elapsed_duration(duration_ms)
        duration_ms = duration_ms.to_f
        return "" if duration_ms.negative?
        return "#{duration_ms.round}ms" if duration_ms < 500

        seconds = duration_ms / 1000
        return "#{seconds.round(1)}s" if seconds < 10
        return "#{seconds.round}s" if seconds < 60

        total_seconds = seconds.round
        "#{total_seconds / 60}m #{format('%02d', total_seconds % 60)}s"
      end

      def paint(text, code)
        return text unless color_output?

        "\e[#{code}m#{text}\e[0m"
      end

      def color_output?
        return false unless $stdout.tty?
        return false if ENV.key?("NO_COLOR")

        ENV.fetch("TERM", "") != "dumb"
      end
    end
  end
end
