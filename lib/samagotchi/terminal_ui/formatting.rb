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
