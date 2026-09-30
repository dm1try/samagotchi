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
        elapsed_suffix = duration_ms.nil? ? "" : " (#{format_elapsed_duration(duration_ms)})"
        "#{paint('tool>', 36)} #{activity[:action]} (#{activity[:tool]}#{params_suffix}): #{paint(status, status_color(status))}#{elapsed_suffix}"
      end

      # Green ok, yellow stopped (a wait the user's Stop ended), red the rest.
      def status_color(status)
        { "ok" => 32, "stopped" => 33 }.fetch(status, 31)
      end

      # "[image shot.png 1280×800 · ~1.3k tokens]", dim: a turn's image.
      def format_image_line(ref)
        paint("[image #{ImageRef.label(ImageStore.symbolize(ref))}]", 90)
      end

      STEER_PREVIEW = 80

      # "check-in> nudged: <text>", dim, one line cut: a plugin's steer
      # (Steer) in the running turn or the join's last exchange.
      def format_steer_line(source:, text:)
        first = text.to_s.strip.split("\n").first.to_s
        first = "#{first[0, STEER_PREVIEW - 1]}…" if first.length > STEER_PREVIEW || text.to_s.strip.include?("\n")
        paint("#{source.to_s.empty? ? "plugin" : source}> nudged: #{first}", 90)
      end

      # "↻ empty answer, asking again (1/1)": the loop retries an empty answer.
      def format_empty_retry_line(event)
        paint("↻ empty answer, asking again (#{event[:attempt]}/#{event[:of]})", 90)
      end

      # " → image 1280×800" after a tool line whose tool read an image.
      def format_tool_image_suffix(images)
        refs = Array(images).map { |ref| ImageStore.symbolize(ref) }
        return "" if refs.empty?

        " #{paint(refs.map { |ref| "→ image #{ref[:width]}×#{ref[:height]}" }.join(", "), 90)}"
      end

      # An edit/write row's change, after the row: " +3 −1" (green, red).
      # +diff+ is EditPreview's hash, symbol or string keys (SSE, snapshot).
      def format_tool_diff_suffix(diff)
        return "" unless diff.is_a?(Hash)

        get = ->(key) { diff[key] || diff[key.to_s] }
        " #{paint("+#{get.(:added).to_i}", 32)} #{paint("\u2212#{get.(:removed).to_i}", 31)}"
      end

      # A card (Engine#show_card) as a framed block: the title and its
      # source, the body as wrapped plain text (no terminal markdown), and
      # one `→ <command>` line per action, the label after it when it says
      # more. +updated+: a card shown again under its id.
      # @param card [Hash] title:, source:, body:, level:, actions:
      # @param width [Integer, nil] columns (#card_width by default)
      def card_block(card, updated: false, width: nil)
        width = [(width || card_width).to_i, 24].max
        rail = paint("│", 90)
        title = card[:title].to_s
        title += " (updated)" if updated
        source = card[:source].to_s
        head = paint("┌ #{title}", card[:level].to_s == "warn" ? 33 : 1)
        head += paint(" · #{source}", 90) unless source.empty?
        lines = [head]
        wrap_plain(strip_markdown(card[:body].to_s), width - 2).each { |line| lines << (line.empty? ? rail : "#{rail} #{line}") }
        Array(card[:actions]).each do |action|
          command = action[:command].to_s
          label = action[:label].to_s
          line = "#{rail} #{paint("→ #{command}", 36)}"
          line += paint("  #{label}", 90) unless label.empty? || label == command
          lines << line
        end
        lines << paint("└", 90)
        lines.join("\n")
      end

      # A card body's markdown made plain, cheaply (there is no terminal
      # markdown): **x** and __x__ are x, backticks and code fences go, and
      # so do headings' #s. Lists stay as they are.
      def strip_markdown(text)
        text.gsub(/^[ \t]*```.*(?:\n|\z)/, "")
            .gsub(/^[ \t]{0,3}\#{1,6}[ \t]+/, "")
            .gsub(/\*\*(.+?)\*\*/, '\1')
            .gsub(/__(.+?)__/, '\1')
            .delete("`")
      end

      # The columns a card is wrapped to: the terminal's (a view with a
      # surface asks it).
      def card_width
        surface = instance_variable_defined?(:@screen) ? @screen : instance_variable_get(:@surface)
        surface.respond_to?(:columns) ? surface.columns : (IO.console&.winsize&.last || 80)
      end

      # +text+ wrapped at word boundaries to +width+ columns, its own line
      # breaks kept (a blank line stays blank), a word longer than a line
      # split. Trailing blank lines dropped.
      def wrap_plain(text, width)
        width = [width, 8].max
        lines = text.gsub("\r\n", "\n").rstrip.split("\n", -1).flat_map do |raw|
          raw = raw.rstrip
          next [""] if raw.empty?

          indent = raw[/\A */]
          out = []
          line = +""
          raw.split(/ +/).reject(&:empty?).each do |word|
            while word.length > width - indent.length
              out << "#{indent}#{line}".rstrip unless line.empty?
              line = +""
              out << "#{indent}#{word[0, width - indent.length]}"
              word = word[(width - indent.length)..]
            end
            if !line.empty? && indent.length + line.length + 1 + word.length > width
              out << "#{indent}#{line}"
              line = +""
            end
            line << (line.empty? ? word : " #{word}")
          end
          out << "#{indent}#{line}" unless line.empty?
          out
        end
        text.strip.empty? ? [] : lines
      end

      # ── Turn ends: one set of words for the REPL, attached mode and the
      # web (timing.js cancelLineText, format.js failedTurnText) ──────────

      # A cancel's reason as the UIs name it (anything else as it is).
      CANCEL_REASONS = { "ctrl_c" => "Ctrl-C", "user" => "stopped", "hook" => "by a hook" }.freeze
      # Under a canceled prompt turn (a canceled continue is back where it
      # started): its partial progress stays in the conversation.
      ROLLBACK_HINT = "partial progress kept; !rollback restores the pre-turn state"

      # "✕ turn canceled (Ctrl-C) · 3.1s"
      def turn_canceled_line(reason, duration_ms)
        label = reason.to_s.empty? ? nil : CANCEL_REASONS.fetch(reason.to_s, reason.to_s)
        "#{paint("✕", 33)} turn canceled#{" (#{label})" if label}#{turn_duration_suffix(duration_ms)}"
      end

      # "✕ turn failed: <summary> · 2.0s"
      def turn_failed_line(detail, duration_ms)
        "#{paint("✕", 31)} turn failed: #{detail}#{turn_duration_suffix(duration_ms)}"
      end

      # A dim, indented line under a turn's end: what became of its prompt.
      def turn_end_hint(text) = "  #{paint(text, 90)}"

      def turn_duration_suffix(duration_ms)
        duration_ms.nil? ? "" : " · #{format_elapsed_duration(duration_ms)}"
      end

      private

      # The recap shown on return: dim, one "recap>" block, noting how many
      # turns came since it was written.
      def recap_block(text, turns_since: 0)
        n = turns_since.to_i
        note = if n == 1 then " (before the last turn)"
               elsif n > 1 then " (before the last #{n} turns)"
               else ""
               end
        text.to_s.strip.lines.map(&:chomp).each_with_index.map do |line, i|
          paint(i.zero? ? "recap#{note}> #{line}" : line, 90)
        end.join("\n")
      end

      RECAP_OFF_TEXT = "recap is off (recap: false in config.yml, or SAMAGOTCHI_RECAP_ENABLED=false)"

      # What /recap says (the REPL's words, attached mode's too): the saved
      # recap, then what came of asking for a new one.
      # @param saved [Hash, nil] {text:, turns_since:}
      # @param request [Symbol, String, nil] IdleRecap#request_now's answer
      def recap_command_text(enabled:, saved: nil, request: nil, min_user_turns: nil)
        return RECAP_OFF_TEXT unless enabled

        saved = saved&.transform_keys(&:to_sym)
        lines = []
        lines << recap_block(saved[:text], turns_since: saved[:turns_since]) if saved
        lines << case request&.to_sym
                 when :started, :in_flight then "writing a recap…"
                 when :nothing_new then saved ? "(nothing new since this recap)" : "no recap yet: nothing to recap"
                 when :too_short then "no recap yet: it needs at least #{min_user_turns} user turns"
                 when :busy then saved ? nil : "no recap yet: a turn is running; one is written once the session is idle"
                 when :failed then "(could not ask for a recap)"
                 end
        lines.compact.join("\n")
      end

      # ── The status line (the REPL's, and attached mode's idle one) ────────

      # status.line: off hides it.
      STATUS_LINE_OFF = "off"

      def status_line_enabled?
        value = Samagotchi::Config.get("status.line").to_s.strip.downcase
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

      # @param label [String] "mem" for the used memories, "muted" for the
      #   session's --mute list
      def status_memory_text(names, limit, label: "mem")
        names = Array(names)
        return "" if names.empty?

        visible = names.first(limit)
        suffix = names.length > visible.length ? ", +#{names.length - visible.length}" : ""
        "#{label}: #{visible.join(', ')}#{suffix}"
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

        tokens = snapshot[:tokens] || {}
        token_src_label = case tokens[:source]
                          when "server" then "server-reported"
                          when "estimate" then "estimated (chars/4)"
                          when "mixed" then "server-reported, some estimated"
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
        # Summed over every request: each prompt is sent in full again.
        lines << "tokens in/out:    #{tokens[:prompt_sum].to_i}/#{tokens[:completion_sum].to_i} (all requests, #{token_src_label})"
        lines << "gen latency (ms): #{snapshot[:gen_latency_ms]}"
        lines << "cancellations:    #{snapshot[:cancellations]}"
        lines << "retries:          #{snapshot[:retries]}"
        context = snapshot[:context] || {}
        if context[:used_tokens]
          pct = context[:window_tokens].to_i.positive? ? format(" (%.1f%%)", context[:used_tokens] * 100.0 / context[:window_tokens]) : ""
          lines << "context used:     #{context[:used_tokens]} tokens#{pct}"
        end
        lines << "context window:   #{context[:window_tokens]} tokens (#{context[:window_source]})" if context[:window_tokens]
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
