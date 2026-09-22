# frozen_string_literal: true

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

      private

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
