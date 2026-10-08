# frozen_string_literal: true

require_relative "../client_id"
require_relative "../served_model"
require_relative "../image_store"
require_relative "../turn_note"
require_relative "../steer"
require_relative "../memory_bundle/index_size"
require_relative "../prompt_note"

module Samagotchi
  class TerminalUI
    # Line formatting shared by the REPL and the attached view: colour, the
    # `tool>` line, elapsed durations. Pure apart from reading whether
    # $stdout is a colour terminal.
    module Formatting
      def format_tool_activity_line(activity, duration_ms: nil)
        status = activity[:status].to_s
        elapsed_suffix = duration_ms.nil? ? "" : " (#{format_elapsed_duration(duration_ms)})"
        "#{paint("tool>", 36)} #{activity[:action]} (#{activity[:tool]}#{tool_params_suffix(activity)}): " \
          "#{paint(status, status_color(status))}#{elapsed_suffix}"
      end

      # What a tool line says the call did: the model's description of a
      # command (": List the specs") in place of its cut params, else the
      # params, dim.
      def tool_params_suffix(activity)
        description = activity[:description].to_s.strip
        return ": #{description}" unless description.empty?

        params = activity[:params].to_s.strip
        params.empty? ? "" : " #{paint(params, 90)}"
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

      # Who a steer names as its sender: a plugin's own label, chi's sender
      # ids in words (the web's format.js steerSender agrees;
      # spec/shared/labels_matrix.json). "": no one named.
      STEER_SENDERS = { "parent_agent" => "parent agent", "chi_send" => "chi send", "plugin_send" => "plugin",
                        "delegate_report" => "delegate report" }.freeze

      def steer_sender(source)
        STEER_SENDERS.fetch(source.to_s, source.to_s)
      end

      # "check-in> nudged: <text>", dim, one line cut: a plugin's steer
      # (Steer) in the running turn or the join's last exchange.
      def format_steer_line(source:, text:)
        first = text.to_s.strip.split("\n").first.to_s
        first = "#{first[0, STEER_PREVIEW - 1]}…" if first.length > STEER_PREVIEW || text.to_s.strip.include?("\n")
        sender = steer_sender(source)
        paint("#{sender.empty? ? "plugin" : sender}> nudged: #{first}", 90)
      end

      # "↻ empty answer, asking again (1/1)": the loop retries an empty answer;
      # "↻ cut by loop-guard, asking again (1/1)" after a plugin cut it;
      # "↻ malformed answer, …" after a corrupt native generation.
      def format_empty_retry_line(event)
        what = if event[:stopped_by] then "cut by #{event[:stopped_by]}"
               elsif event[:malformed] then "malformed answer"
               else "empty answer"
               end
        paint("↻ #{what}, asking again (#{event[:attempt]}/#{event[:of]})", 90)
      end

      # "↪ cut in for your message": a message for the running turn cut a
      # generation that was only thinking (Engine#cut_for_steer); an empty
      # or unknown source is the user's.
      STEER_CUT_FOR = { "chi_send" => "a message sent with chi send", "parent_agent" => "the parent agent's message" }.freeze

      def format_steer_cut_line(event)
        paint("↪ cut in for #{STEER_CUT_FOR.fetch(event[:source].to_s, "your message")}", 90)
      end

      # "✂ forgot 2 outputs, stubbed 1 stale read · frees ~4.1k tokens (paid
      # off)": a batch of LLM context edits went in (LLMContextNotice builds
      # the line; the web prints the same), dim like the retry row.
      def format_llm_context_line(event)
        paint(event[:text].to_s.empty? ? "✂ LLM context edited" : event[:text].to_s, 90)
      end

      # "no answer: the model returned nothing (after 1 retry)", dim like the
      # retry row: a turn that ended with no answer (TurnNote.empty_answer_line).
      def format_empty_answer_line(retries)
        paint(TurnNote.empty_answer_line(retries), 90)
      end

      # "retrying (1/3 in 0.5s): Errno::ECONNREFUSED": the retry of all the
      # retries there will be (as the web counts), the wait before it, and
      # what failed (generation_retrying).
      def format_generation_retry_line(event)
        return "retrying (attempt #{event[:attempt]})" unless event[:max_retries]

        text = "retrying (#{event[:attempt]}/#{event[:max_retries]} in #{format("%.1f", event[:next_delay].to_f)}s)"
        event[:error_class].to_s.empty? ? text : "#{text}: #{event[:error_class]}"
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
        " #{paint("+#{get.call(:added).to_i}", 32)} #{paint("\u2212#{get.call(:removed).to_i}", 31)}"
      end

      # Prompt labels by the sender's client_id: a whole id, or a prefix
      # (ending in ":") it starts with (turn_events.js CLIENT_LABELS;
      # spec/shared/labels_matrix.json).
      CLIENT_LABELS = { ClientId::WEB_PREFIX => "web", ClientId::TUI_PREFIX => "tui", ClientId::SYSTEM_PREFIX => "reminder",
                        ClientId::DELEGATE_PREFIX => "delegate", ClientId::CHILD_PREFIX => "delegate report",
                        ClientId::CLI_SEND => "chi send", ClientId::CLI_ANSWER => "chi answer",
                        ClientId::PLUGIN => "plugin" }.freeze
      # A client id chi doesn't know: not the user (ClientId.human?).
      AUTOMATIC_LABEL = "automatic"

      # Who sent a line, by its client_id: CLIENT_LABELS by the whole id or
      # its prefix, a turn an attached context source started
      # (context:<name>) as "context <name> changed", AUTOMATIC_LABEL for
      # an id chi doesn't know; +fallback+ for none (the user's own).
      def client_label(client_id, fallback = "user")
        return fallback unless client_id

        id = client_id.to_s
        name = id.delete_prefix(ClientId::CONTEXT_PREFIX)
        return "context #{name} changed" if id.start_with?(ClientId::CONTEXT_PREFIX) && !name.empty?

        prefix = id[/\A[^:]*:/]
        CLIENT_LABELS[id] || (prefix && CLIENT_LABELS[prefix]) || AUTOMATIC_LABEL
      end

      # "web> <prompt>": a prompt, labelled by who sent it; nil: the label alone.
      def prompt_line(client_id, prompt)
        "#{paint("#{client_label(client_id)}>", 35)}#{" #{prompt}" unless prompt.nil?}"
      end

      # "delegate report> 3f2a1c9e answered: <the reply's first line>": a
      # delegate child's report (ChildReports) merged into the turn.
      def report_line(report)
        id = report[/\Asession: (\S+)/, 1].to_s[0, 8]
        status = report[/^status: (.*)$/, 1]
        rest = report.split("\n").drop(2).reject { |line| line.strip.empty? || line == "---" }.first.to_s
        rest = "#{rest[0, STEER_PREVIEW - 1]}…" if rest.length > STEER_PREVIEW
        "#{paint("#{CLIENT_LABELS[ClientId::CHILD_PREFIX]}>", 35)} #{[id, status].compact.join(" ")}#{": #{rest}" unless rest.empty?}"
      end

      # The last prompt as a join shows it: a delegate report (a wake
      # turn's) as the child's lines, anything else as the user's.
      def join_prompt_line(message)
        source = (message[:source] || message["source"]).to_s
        content = (message[:content] || message["content"]).to_s
        return prompt_line(nil, content) unless source == Steer::DELEGATE_REPORT

        content.split(/\n\n(?=session: )/).map { |report| report_line(report) }.join("\n")
      end

      # "reminder: a, b": the reminders a turn runs for (names or hashes).
      def reminder_line(reminders)
        names = Array(reminders).filter_map { |r| r.is_a?(Hash) ? r[:name] : r }
        names.empty? ? "reminder" : "reminder: #{names.join(", ")}"
      end

      CONTEXT_NOTE_PREVIEW = 60

      # "note from slack: <first line>", cut to one line.
      def context_note_line(label, text)
        lines = text.to_s.strip.split("\n")
        first = lines.first.to_s
        if first.length > CONTEXT_NOTE_PREVIEW
          first = "#{first[0, CONTEXT_NOTE_PREVIEW - 1]}\u2026"
        elsif lines.size > 1
          first += " \u2026"
        end
        paint("note from #{label || "?"}: #{first}", 2)
      end

      # A tool call from the snapshot: it has no action text, only the tool.
      def snapshot_tool_line(part)
        status = part[:status].to_s
        "#{paint("tool>", 36)} #{part[:tool]}#{tool_params_suffix(part)}: #{paint(status, status_color(status))}" \
          "#{format_tool_image_suffix(part[:images])}#{format_tool_diff_suffix(part[:diff])}"
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

      # A cancel's reason as the UIs name it (anything else as it is);
      # spec/shared/labels_matrix.json pins it for both.
      CANCEL_REASONS = { "ctrl_c" => "Ctrl-C", "user" => "stopped", "hook" => "by a hook" }.freeze
      # A canceled turn's mark: a stop someone chose (Ctrl-C, Stop, a hook),
      # not an error's ✕ (timing.js STOP_MARK; the labels matrix pins it).
      STOP_MARK = "■"
      # Under a canceled prompt turn (a canceled continue is back where it
      # started): its partial progress stays in the conversation.
      ROLLBACK_HINT = "partial progress kept; !rollback restores the pre-turn state"

      # "■ turn canceled (Ctrl-C) · 3.1s"; a hook's stop that names who
      # (+by+, turn_canceled's cancelled_by): "■ turn stopped by loop-guard"
      def turn_canceled_line(reason, duration_ms, by: nil)
        if reason.to_s == "hook" && !by.to_s.empty?
          return "#{paint(STOP_MARK, 33)} turn stopped by #{by}#{turn_duration_suffix(duration_ms)}"
        end

        label = reason.to_s.empty? ? nil : CANCEL_REASONS.fetch(reason.to_s, reason.to_s)
        "#{paint(STOP_MARK, 33)} turn canceled#{" (#{label})" if label}#{turn_duration_suffix(duration_ms)}"
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

      # "87 tok/s", "1.9k tok/s"; "~64 tok/s" for an estimate; "" without a
      # speed. The web says the same (ctx.js speedText;
      # spec/shared/labels_matrix.json).
      def speed_text(tps, source)
        value = tps.to_f
        return "" unless value.positive?

        number = value >= 1000 ? "#{format("%.1f", (value / 100).round / 10.0)}k" : value.round.to_s
        "#{"~" if source.to_s == "estimate"}#{number} tok/s"
      end

      # "~3.4k tokens in this session's prompt (system 2.0k, project 1.4k)":
      # the memory indexes the session's prompt holds (the snapshot's
      # memory_index, symbol or string keys); "" without one. As ctx.js
      # memoryIndexText (spec/shared/labels_matrix.json).
      def memory_index_text(block)
        return "" unless block.is_a?(Hash)

        scopes = %w[system project].filter_map do |scope|
          figures = block[scope] || block[scope.to_sym]
          tokens = figures.is_a?(Hash) ? (figures["tokens"] || figures[:tokens]) : nil
          [scope, tokens.to_i] if tokens.is_a?(Numeric)
        end
        return "" if scopes.empty?

        count = ->(tokens) { MemoryBundle::IndexSize.count_text(tokens) }
        "~#{count.call(scopes.sum(&:last))} tokens in this session's prompt " \
          "(#{scopes.map { |scope, tokens| "#{scope} #{count.call(tokens)}" }.join(", ")})"
      end

      # "$0.42"; a cost under a cent keeps four decimals ("$0.0012"); "~$0.12"
      # for an estimate (hosts.<name>.models prices); "" for none. As ctx.js
      # costText.
      def cost_text(cost, estimate: false)
        value = cost.to_f
        return "" unless value.positive?

        "#{"~" if estimate}#{value >= 0.01 ? format("$%.2f", value) : format("$%.4f", value)}"
      end

      # /stats' cost: the reported part and the estimated one, each when present.
      def stats_cost_text(tokens)
        reported = cost_text(tokens[:cost_sum])
        estimated = cost_text(tokens[:cost_estimate_sum], estimate: true)
        return nil if reported.empty? && estimated.empty?
        return "#{reported} (this session only)" if estimated.empty?

        estimate = "#{estimated} from hosts.<name>.models prices"
        "#{reported.empty? ? estimate : "#{reported} reported + #{estimate}"} (this session only)"
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

        row = cap_preview_text("status> #{segments.join(" | ")}", width)
        [color_output? ? paint(row, 90) : row]
      end

      # Longest asked-for name the status line keeps next to a served one.
      STATUS_ASKED_MAX = 24

      # +served+ / +served_for+: the model the server said it served for the
      # name asked (see Engine#served_model); shown first when it's another
      # model, unless +expected+ (the host's served: names it).
      def status_model_text(model, default_model, served: nil, served_for: nil, expected: false)
        if !expected && ServedModel.differs?(served_for, served)
          asked = model.to_s.length > STATUS_ASKED_MAX ? "#{model.to_s[0, STATUS_ASKED_MAX - 1]}…" : model
          return "model=#{served} (served; asked #{asked})"
        end
        return "model=#{model}" if default_model.nil? || model == default_model

        "model=#{model} (default: #{default_model})"
      end

      # @param estimate [Hash, nil] the kernel's estimate ({est_pct:, bucket:})
      def status_context_text(estimate: nil)
        return "" unless estimate.is_a?(Hash)

        pct = format("%.1f", estimate[:est_pct].to_f)
        bucket = estimate[:bucket].to_s
        return "ctx=#{pct}%" if bucket.empty?

        "ctx=#{pct}% (#{bucket})"
      end

      # @param label [String] "mem" for the used memories, "muted" for the
      #   session's --mute list
      def status_memory_text(names, limit, label: "mem")
        names = Array(names)
        return "" if names.empty?

        visible = names.first(limit)
        suffix = names.length > visible.length ? ", +#{names.length - visible.length}" : ""
        "#{label}: #{visible.join(", ")}#{suffix}"
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
        lines << "tokens in/out:    #{tokens[:prompt_sum].to_i}/#{tokens[:completion_sum].to_i} (all requests, #{token_src_label})" \
                 "#{token_breakdown_text(tokens)}"
        speed = stats_speed_text(tokens)
        lines << "speed:            #{speed}" if speed
        cost = stats_cost_text(tokens)
        lines << "cost:             #{cost}" if cost
        lines << "gen latency (ms): #{snapshot[:gen_latency_ms]}"
        lines << "cancellations:    #{snapshot[:cancellations]}"
        lines << "retries:          #{snapshot[:retries]}"
        # A looped session: loop-guard's cuts, or thinking that ran to the cap.
        lines << "thinking cuts:    #{snapshot[:cuts].to_i}"
        lines << "output cap hits:  #{snapshot[:capped].to_i}"
        context = snapshot[:context] || {}
        if context[:used_tokens]
          pct = context_pct_text(context, snapshot[:llm_context])
          lines << "context used:     #{context[:used_tokens]} tokens#{pct}"
        end
        lines << "context window:   #{context[:window_tokens]} tokens (#{context[:window_source]})" if context[:window_tokens]
        lines << "prompt profile:   #{snapshot[:profile]} (#{snapshot[:profile_source]})" if snapshot[:profile]
        memory_index = memory_index_text(snapshot[:memory_index])
        lines << "memory index:     #{memory_index}" unless memory_index.empty?
        # The model notes the session's prompt carried (Engine#prompt_notes).
        notes = PromptNote.text(snapshot[:prompt_notes])
        lines << "model notes:      #{notes}" unless notes.empty?
        llm_context = llm_context_stats_text(snapshot[:llm_context])
        lines << "llm context:      #{llm_context}" if llm_context
        if snapshot[:served_model]
          asked = snapshot[:served_model_for]
          differs = !snapshot[:served_expected] && ServedModel.differs?(asked, snapshot[:served_model])
          note = differs ? " (asked for #{asked})" : ""
          lines << "served model:     #{snapshot[:served_model]}#{note}"
        end
        lines.join("\n")
      end

      # " (25.0% of the 64000 budget)" when the session's llm_context budget
      # is set and smaller than the window, else " (12.5%)": the live meter
      # counts against the smaller of the two (ContextStatus#counted_against),
      # and so does this. The summary is Explained#summary (symbol or string
      # keys: the attached TUI's come as JSON); "" when there is no window.
      def context_pct_text(context, llm_context)
        window = context[:window_tokens].to_i
        return "" unless window.positive?

        summary = llm_context.is_a?(Hash) ? llm_context : {}
        budget = summary[:budget_tokens] || summary["budget_tokens"]
        budget = nil unless budget.is_a?(Numeric) && budget.positive?
        used = context[:used_tokens] * 100.0
        return format(" (%.1f%%)", used / window) unless budget && budget < window

        format(" (%.1f%% of the %d budget)", used / budget, budget)
      end

      # "stale,forget (the session); apply turn_end (models: x); budget
      # 64000 (the session)" for /stats (Explained#summary; symbol or
      # string keys, the attached TUI's come as JSON); nil without one.
      def llm_context_stats_text(summary)
        return nil unless summary.is_a?(Hash)

        get = ->(key) { summary[key] || summary[key.to_s] }
        budget = get.call(:budget_tokens) ? "#{get.call(:budget_tokens)} tokens" : "off"
        "#{get.call(:strategy)} (#{get.call(:strategy_where)}); apply #{get.call(:apply)} (#{get.call(:apply_where)}); " \
          "budget #{budget} (#{get.call(:budget_where)})"
      end

      # ", cached 4864 (93%), cache writes 312, re-prefilled 2100, reasoning
      # 212" for the tokens line; the counts a server didn't report are left
      # out (re-prefilled: SessionMetrics' reprefill_sum).
      def token_breakdown_text(tokens)
        cached = tokens[:cached_sum].to_i
        reasoning = tokens[:reasoning_sum].to_i
        prompt = tokens[:prompt_sum].to_i
        text = +""
        text << ", cached #{cached} (#{(cached * 100.0 / prompt).round}%)" if cached.positive? && prompt.positive?
        text << ", cache writes #{tokens[:cache_write_sum].to_i}" if tokens[:cache_write_sum].to_i.positive?
        text << ", re-prefilled #{tokens[:reprefill_sum].to_i}" if tokens[:reprefill_sum].to_i.positive?
        text << ", reasoning #{reasoning}" if reasoning.positive?
        text
      end

      # "87 tok/s out, 1.9k tok/s prompt (last, server), avg 81 tok/s", or nil
      # before a generation had a speed. The prompt (prefill) speed only when
      # the server reported it.
      def stats_speed_text(tokens)
        last = tokens[:last_decode_tps]
        return nil unless last

        source = tokens[:tps_source].to_s
        text = "#{speed_text(last, source)} out"
        text << ", #{speed_text(tokens[:last_prefill_tps], "server")} prompt" if tokens[:last_prefill_tps]
        text << " (last, #{source})"
        text << ", avg #{speed_text(tokens[:avg_decode_tps], source)}" if tokens[:avg_decode_tps]
        text
      end

      def format_elapsed_duration(duration_ms)
        duration_ms = duration_ms.to_f
        return "" if duration_ms.negative?
        return "#{duration_ms.round}ms" if duration_ms < 500

        seconds = duration_ms / 1000
        return "#{seconds.round(1)}s" if seconds < 10
        return "#{seconds.round}s" if seconds < 60

        total_seconds = seconds.round
        "#{total_seconds / 60}m #{format("%02d", total_seconds % 60)}s"
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
