# frozen_string_literal: true

require_relative "../client_id"
require_relative "../output_formatter"
require_relative "../steer"

module Samagotchi
  module Web
    # What a participant sees of their session (D5 a): prompts and replies
    # with their authors, one-line tool rows (the tool's name, and a
    # project-relative path for a file tool), turn boundaries, and the
    # waiting states. Never: tool output or arguments, thinking, context
    # notes, plugin steers, automatic input, cards, commands, questions'
    # internals, memories, the working set, cost or timing, host paths.
    #
    # Every read a participant reaches goes through here: the stream's
    # events (#event, ParticipantStreamFilter), the review route's
    # conversation (#messages) and turn in progress (#current_turn). Each
    # is an allowlist that builds a new hash from named fields, so a field
    # added to an event later never reaches a participant until it is
    # named here, and an event type not named is dropped. Every string
    # that goes out passes Redact (secret shapes, the owner's token, the
    # home folder), defence in depth only: the allowlist is the control.
    # Pure: no I/O; keys of what comes in may be strings (JSON) or symbols.
    module ParticipantView
      # Who is looking: +author+ the participant's ("p:<id>"; nil for the
      # owner through the participant view: nothing is theirs), +cwd+ the
      # session's folder (tool paths are shown relative to it, only inside
      # it), +home+ the folder shown as ~, +secrets+ literal strings never
      # shown (the owner's token).
      Viewer = Data.define(:author, :cwd, :home, :secrets) do
        def initialize(author: nil, cwd: nil, home: Dir.home, secrets: [])
          super(author: author, cwd: cwd, home: home, secrets: Array(secrets).map(&:to_s).reject(&:empty?))
        end

        def own?(author) = !self.author.nil? && author.to_s == self.author
      end

      # The stream's event types a participant gets, each rebuilt by the
      # method named. Every other type is dropped.
      EVENTS = {
        "turn_started" => :turn_started,
        "turn_completed" => :turn_ended,
        "turn_canceled" => :turn_ended,
        "turn_failed" => :turn_ended,
        "generation_chunk" => :generation_chunk,
        "generation_retrying" => :generation_retrying,
        "tool_call_started" => :tool_call_started,
        "tool_call_completed" => :tool_call_completed,
        # Queue changes: the page re-reads its review data, which has the
        # queue as the participant may see it.
        "turn_enqueued" => :bare,
        "turn_dequeued" => :bare,
        "input_merged" => :bare,
        # The owner's question, approval or Continue offer: "waiting for the
        # owner", nothing of it.
        "question_requested" => :bare,
        "question_answered" => :bare,
        "question_cancelled" => :bare,
        "continue_offered" => :bare,
        "continue_resolved" => :bare,
        # The cursor can't be replayed (or a join): the page re-reads.
        "snapshot" => :bare,
        "reset" => :bare
      }.freeze

      # The types chi emits that a participant never gets, named so the
      # spec that walks every emitted type (spec/web/participant_view_spec)
      # fails for a new one until it is decided here or in EVENTS. Not
      # named is dropped all the same.
      DROPPED = %w[
        after_generation after_tool_call after_turn answer_display before_generation before_tool_call before_turn
        card command_output command_queued command_ran context_added context_status empty_answer_retry
        generation_cancelled generation_completed generation_progress generation_started guardrail_warning hook_notice
        llm_context_edited merged_input participants_changed pending_input_merged plugin_init_finished
        plugin_init_started plugin_init_wait prompt_restored question question_relay reasoning_history_refused
        recap_ready reminder_injected sampling_refused session_end session_start side_usage steer_cut thinking_dropped
        thinking_refused tool_dispatch_completed tool_dispatch_started used_memories_updated working_set_updated
      ].freeze

      # A merged input line's saved sources a participant sees: a person's
      # (the owner, chi send, a participant). A delegate's report, a
      # plugin's or an automatic client's input is not.
      PERSON_SOURCES = ["", "chi_send", Steer::PARTICIPANT_SOURCE].freeze

      # A tool call's status words a row may carry.
      STATUSES = %w[ok error blocked stopped denied].freeze

      module_function

      # @param event [Hash] a client event (ClientEvent's shape; string keys
      #   from the stream's JSON)
      # @return [Hash, nil] what a participant gets, string keys; nil: nothing
      def event(event, viewer)
        return nil unless event.is_a?(Hash)

        type = field(event, :type).to_s
        method = EVENTS[type] or return nil
        out = send(method, event, viewer)
        out && Redact.deep(out, viewer)
      end

      # A turn's start: who wrote it, and its prompt when a person sent it
      # (an automatic turn's prompt, a reminder's or a task's, is not
      # shown). +mine+ when the viewer queued it.
      def turn_started(event, viewer)
        origin = field(event, :origin)
        origin = {} unless origin.is_a?(Hash)
        author = field(event, :author) || field(origin, :author)
        out = { "type" => "turn_started", **id_fields(event) }
        out.merge!(author_fields(author, field(event, :author_name), viewer))
        prompt = field(event, :prompt)
        if field(event, :continue)
          out["continue"] = true
        elsif person_turn?(origin)
          out["prompt"] = prompt.to_s unless prompt.nil?
        else
          out["automatic"] = true
        end
        out
      end

      def turn_ended(event, _viewer)
        { "type" => field(event, :type).to_s, **id_fields(event) }
      end

      # The reply's visible text only: never thinking, a tool call's bytes
      # or the provider's counts. A chunk with no text is dropped.
      def generation_chunk(event, _viewer)
        text = field(event, :text)
        return nil unless text.is_a?(String) && !text.empty?

        { "type" => "generation_chunk", "text" => text, **iteration(event) }
      end

      # A dropped stream asked again: its text so far is void when restarted.
      def generation_retrying(event, _viewer)
        out = { "type" => "generation_retrying", **iteration(event) }
        out["restarted"] = true if field(event, :restarted)
        out
      end

      def tool_call_started(event, viewer)
        { "type" => "tool_call_started", **tool_row(field(event, :tool), field(event, :ref), viewer), **call_ids(event) }
      end

      def tool_call_completed(event, _viewer)
        out = { "type" => "tool_call_completed", **call_ids(event) }
        activity = field(event, :activity)
        status = activity.is_a?(Hash) ? field(activity, :status).to_s : ""
        out["status"] = status if STATUSES.include?(status)
        out
      end

      # Its type alone (and the cursor it was sent at).
      def bare(event, _viewer)
        { "type" => field(event, :type).to_s, **seq(event) }
      end

      # @param shown [Array<Hash>] the owner's display messages
      #   (App#messages_for_display with parts: true)
      # @param automatic [#include?] the ids of turns no person sent (their
      #   analytics records' +automatic+, and the running one's): their
      #   prompt is shown as an automatic turn, without its text
      # @return [Array<Hash>] {role: "user", content, turn_id, author,
      #   author_name, mine, automatic, images} and {role: "assistant",
      #   content, tools: [{tool, path}]}; no notes, steers, automatic
      #   input or empty-answer markers. html is added by the caller, from
      #   this (redacted) content.
      def messages(shown, viewer, automatic: [])
        Array(shown).filter_map do |message|
          next unless message.is_a?(Hash)

          out = case field(message, :role).to_s
                when "user" then user_message(message, viewer, automatic)
                when "assistant" then assistant_message(message, viewer)
                end
          out && Redact.deep(out, viewer)
        end
      end

      # A user message a participant sees: a turn's prompt (it has the
      # turn's id) or a person's line merged into a turn. Every other user
      # message is dropped: the owner's `!` line and its output, a
      # delegate's report (a wake turn's input), the notes chi adds (a
      # Continue the owner declined). Any message from a source that isn't a
      # person's is dropped whatever it is.
      def user_message(message, viewer, automatic = [])
        source = field(message, :source).to_s
        return nil unless PERSON_SOURCES.include?(source)

        turn_id = field(message, :turn_id)
        merged = field(message, :merged)
        return nil unless turn_id || merged

        out = { "role" => "user" }
        if turn_id && automatic.include?(turn_id.to_s)
          out.merge!("content" => "", "automatic" => true, "turn_id" => turn_id.to_s)
          return out
        end
        out["content"] = field(message, :content).to_s
        out["turn_id"] = turn_id.to_s if turn_id
        out["merged"] = true if merged
        out.merge!(author_fields(field(message, :author), field(message, :author_name), viewer))
        images = field(message, :images)
        out["images"] = images.size if images.is_a?(Array) && !images.empty?
        out
      end

      def assistant_message(message, viewer)
        parts = field(message, :parts)
        tools = parts.is_a?(Hash) ? Array(field(parts, :tools)) : []
        rows = tools.filter_map { |tool| tool.is_a?(Hash) ? tool_row(field(tool, :tool), field(tool, :ref), viewer) : nil }
        content = field(message, :content).to_s
        return nil if content.strip.empty? && rows.empty?

        out = { "role" => "assistant", "content" => content }
        out["tools"] = rows unless rows.empty?
        out
      end

      # The turn in progress (TurnAccumulator#current_turn, string keys
      # from the Bridge's snapshot) as a participant sees it: its start
      # (#turn_started's fields), the reply's text so far, its tool rows,
      # and whether it waits for the owner (a question, an approval).
      # @return [Hash, nil]
      def current_turn(turn, viewer)
        return nil unless turn.is_a?(Hash)

        started = turn_started(turn.merge("type" => "turn_started"), viewer)
        started.delete("type")
        text = +""
        tools = []
        Array(field(turn, :parts)).each do |part|
          next unless part.is_a?(Hash)

          case field(part, :kind).to_s
          when "text" then text << field(part, :text).to_s
          when "tool"
            row = tool_row(field(part, :tool), field(part, :ref), viewer)
            status = field(part, :status).to_s
            row["status"] = status if status == "running" || STATUSES.include?(status)
            tools << row
          end
        end
        out = started.merge("text" => text, "tools" => tools)
        out["waiting_for_owner"] = true if field(turn, :pending_question)
        Redact.deep(out, viewer)
      end

      # A tool row: the tool's name, and for a file tool the path relative
      # to the session's folder when it is inside it. Never its arguments.
      def tool_row(tool, ref, viewer)
        row = { "tool" => tool.to_s }
        path = ref.is_a?(Hash) ? field(ref, :path) : nil
        relative = project_path(path, viewer.cwd, home: viewer.home)
        row["path"] = relative if relative
        row
      end

      # +path+ relative to +cwd+ when it is inside it, else nil. None when
      # the session's folder is the home folder or / (everything would be
      # "inside": chi's own state and config, other projects).
      def project_path(path, cwd, home: nil)
        return nil unless path.is_a?(String) && cwd.is_a?(String) && !cwd.empty?

        root = File.expand_path(cwd)
        return nil if root == "/" || (home && root == File.expand_path(home.to_s))

        full = File.expand_path(path, root)
        return nil unless full.start_with?("#{root}/")

        full.delete_prefix("#{root}/")
      rescue ArgumentError
        nil
      end

      # A turn's author as a participant sees it: the participant's id and
      # name, or none for the owner's; +mine+ for the viewer's own.
      def author_fields(author, name, viewer)
        return {} unless Steer.participant_author?(author)

        out = { "author" => author.to_s }
        out["author_name"] = name.to_s if name.is_a?(String) && !name.empty?
        out["mine"] = true if viewer.own?(author)
        out
      end

      # Sent by a person (the owner's web or TUI, chi send, a participant),
      # or with no origin (an in-process turn: the owner's).
      def person_turn?(origin)
        client_id = field(origin, :client_id)
        client_id.nil? || ClientId.human?(client_id)
      end

      def id_fields(event)
        out = seq(event)
        turn_id = field(event, :turn_id)
        out["turn_id"] = turn_id.to_s if turn_id
        out
      end

      def seq(event)
        seq = field(event, :event_seq)
        seq.is_a?(Integer) ? { "event_seq" => seq } : {}
      end

      def iteration(event)
        value = field(event, :iteration)
        value.is_a?(Integer) ? { "iteration" => value } : {}
      end

      def call_ids(event)
        out = iteration(event)
        index = field(event, :call_index)
        out["call_index"] = index if index.is_a?(Integer)
        out
      end

      # Markup a reply may hold whole (closed): kept for the tool rows read
      # from it (MessageParts) and stripped by the display.
      CLOSED_BLOCKS = Regexp.union(OutputFormatter::QWEN_THINK_RE, OutputFormatter::QWEN_TOOL_CALL_RE,
                                   OutputFormatter::GEMMA_TOOL_CALL_RE, OutputFormatter::GEMMA_THOUGHT_RE)
      # A close with no open before it: what came before was thinking (the
      # raw loop saves prefill + response).
      BARE_CLOSES = ["</think>", "<channel|>"].freeze
      # An open with no close after it (a cut-off thought, a tool call the
      # loop recovered): everything from it on is the model's own.
      OPENS = ["<think>", "<tool_call>", "<|tool_call>", "<|channel>", "<|tool_response>", "<tool_response>", "<|think|>"].freeze

      # A saved model message's raw content as a participant may read it:
      # closed blocks kept (the display strips them, its tool rows come from
      # them), anything before a bare close and from an unclosed open on
      # dropped, which the display's strip would only untag (leaving the
      # thinking or the tool call's arguments as text).
      def visible_raw(text)
        held = []
        out = text.to_s.gsub(CLOSED_BLOCKS) do |block|
          held << block
          "\u0000#{held.size - 1}\u0000"
        end
        close = BARE_CLOSES.filter_map { |marker| (at = out.rindex(marker)) && (at + marker.size) }.max
        out = out[close..] if close
        cut = OPENS.filter_map { |marker| out.index(marker) }.min
        out = out[0, cut] if cut
        out.gsub(/\u0000(\d+)\u0000/) { held[Regexp.last_match(1).to_i] }
      end

      def field(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end

      # Secret shapes and host paths out of what a participant gets (the
      # session's folder as relative paths, home as ~). Defence in depth: the
      # allowlist above is the control; this catches a key the model quoted
      # in a reply, or one in a prompt.
      module Redact
        MARK = "[redacted]"
        PATTERNS = [
          /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)/m,
          /\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}/,
          /\bgh[pousr]_[A-Za-z0-9]{20,}/,
          /\bgithub_pat_[A-Za-z0-9_]{20,}/,
          /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
          /\bxox[abprs]-[A-Za-z0-9-]{10,}/,
          /\bchp_[A-Za-z0-9_-]{20,}/,
          /\bAIza[0-9A-Za-z_-]{30,}/,
          /\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}/,
          /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
          %r{https://hooks\.slack\.com/services/[A-Za-z0-9/_-]+}
        ].freeze
        # The value after an Authorization header or a token=/key= pair.
        VALUES = [
          /(\bAuthorization:\s*(?:Bearer\s+|Basic\s+|Token\s+)?)[^\s"'`]+/i,
          /((?<![A-Za-z0-9])[A-Za-z0-9_-]*?(?:token|api[_-]?key|access[_-]?key|secret|password|passwd)["']?\s*[=:]\s*["']?)[^\s"'&`,;}]+/i,
          # A URL's password: scheme://user:PASSWORD@host.
          %r{(\b[a-z][a-z0-9+.-]*://[^/\s:@]+:)[^@\s/]+(?=@)}i
        ].freeze

        module_function

        # +value+ with every string in it redacted (hash values, array items).
        def deep(value, viewer)
          case value
          when String then text(value, viewer)
          when Hash then value.transform_values { |item| deep(item, viewer) }
          when Array then value.map { |item| deep(item, viewer) }
          else value
          end
        end

        def text(value, viewer)
          out = value.dup
          viewer.secrets.each { |secret| out = out.gsub(secret, MARK) }
          PATTERNS.each { |pattern| out = out.gsub(pattern, MARK) }
          VALUES.each { |pattern| out = out.gsub(pattern) { "#{Regexp.last_match(1)}#{MARK}" } }
          out = within(out, viewer.cwd.to_s)
          home = viewer.home.to_s
          out = out.gsub(%r{#{Regexp.escape(home)}(?=/|\b|\z)}, "~") if home.length > 1
          out
        end

        # +text+ with +dir+ (the session's folder) shown relative: "dir/x"
        # as "x", "dir" alone as ".".
        def within(text, dir)
          return text if dir.length < 2

          text.gsub(%r{#{Regexp.escape(dir)}(/|(?=\b|\z))}) { Regexp.last_match(1) == "/" ? "" : "." }
        end
      end
    end
  end
end
