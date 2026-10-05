# frozen_string_literal: true

module Samagotchi
  # A plugin's steer: text a plugin puts into the running turn (Engine#steer),
  # the way a UI's steering does. The drain a loop gets returns items: a
  # String (a user line, as ever) or {text:, source:} (a steer). The user
  # lines merge into one user message as before; each steer follows it as its
  # own user message marked kind: "steer" and source: (the ContextNote keys,
  # which every message copy keeps). The model reads it as user text.
  #
  # The user's own lines merged into a running turn are marked kind:
  # "input": they are part of that turn, not a turn of their own, so a
  # reloaded history keeps the turn in one piece. A line can be a Line
  # naming who sent it (a worker's input from chi send, a delegating parent,
  # a plugin); its input message then carries that source:. The user's own
  # lines carry none, so their saved bytes are as they always were.
  module Steer
    KIND = "steer"
    INPUT_KIND = "input"

    # A drain item for an input line with its sender (source nil = the user).
    # A plain String is still a valid item: the user's line. +mark+: fields
    # its input message carries ({turn_start: true, turn_id:} for the
    # first message of a turn with no prompt, a delegate report's wake
    # turn), nil for none.
    Line = Data.define(:text, :source, :mark) do
      def initialize(text:, source:, mark: nil) = super
    end

    # The client ids whose input is not the user's own words. Literals, not
    # SendCommand::CLIENT_ID / Tools::Delegate::CLIENT_PREFIX, so this file
    # needs no requires (a spec pins them equal).
    CHI_SEND_CLIENT = "cli:send"
    DELEGATE_CLIENT_PREFIX = "delegate:"
    # A delegate child's report (ChildReports::CLIENT_PREFIX).
    CHILD_CLIENT_PREFIX = "child:"
    DELEGATE_REPORT = "delegate_report"
    PLUGIN_CLIENT = "plugin"

    # What one drain brought: the merged user text (nil when none) and how
    # many lines made it, the input messages' text grouped by sender
    # (consecutive lines from one sender form one group), and the steers in
    # order.
    Merge = Struct.new(:content, :count, :inputs, :steers, keyword_init: true) do
      def empty? = content.nil? && steers.empty?

      # The messages it appends: the merged input first (one message per
      # sender run, marked kind input, source: when not the user's), then
      # each steer.
      def messages
        list = inputs.map do |input|
          message = { role: "user", kind: INPUT_KIND }
          message[:source] = input[:source] if input[:source]
          message.merge!(input[:mark]) if input[:mark]
          message.merge(content: input[:content])
        end
        list + steers.map { |steer| Steer.message(**steer) }
      end

      # The :pending_input_merged fields beside iteration and answer;
      # steers: only when there are some, so plain merges stay as they were;
      # reports: the delegate reports' text, one per report (a UI shows
      # each as the child's, not as a merged message).
      def event_fields
        fields = { count: count, content: content }
        fields[:steers] = steers unless steers.empty?
        reports = inputs.select { |input| input[:source] == DELEGATE_REPORT }
                        .flat_map { |input| input[:content].split(/\n\n(?=session: )/) }
        fields[:reports] = reports unless reports.empty?
        fields
      end
    end

    # The one line the model reads above a steer or merged input (the wire
    # only; the saved content stays raw): who sent it, and that it should
    # follow it or, if it asks for nothing, carry on.
    HEADER_TAIL = "mid-task. Follow it; if it asks for nothing, carry on with the task.]"
    SENDERS = {
      "user" => "from the user",
      "parent_agent" => "from the parent agent that started this session",
      "chi_send" => "sent with chi send",
      "plugin_send" => "sent by a plugin"
    }.freeze
    USER_HEADER = "[Steer #{SENDERS["user"]}, #{HEADER_TAIL}".freeze
    # A source whose message is not a steer at all gets its own whole
    # header line here instead of "[Steer <sender>, …]". A delegate
    # child's report (ChildReports) is chi's news, not the user's: its
    # wording was picked on small models (it keeps them on their own task
    # mid-turn and off delegate_result; "Follow it" made one apply the
    # child's fix unasked).
    HEADERS = {
      "delegate_report" => "[Delegate report, delivered by chi when your delegate session ended its turn; " \
                           "not your user's message. Tell your user what it found or what went wrong, in your own " \
                           "words; if you are in the middle of a task, include it in your reply and finish the task. " \
                           "Don't call delegate_result for it; to retry or redirect that child, use delegate with " \
                           "its session:.]"
    }.freeze

    module_function

    # The saved source of a worker input line from +client_id+: nil for the
    # user (no client id, the web, an attached TUI, anything unknown).
    def source_for_client(client_id)
      id = client_id.to_s
      if id == CHI_SEND_CLIENT then "chi_send"
      elsif id.start_with?(DELEGATE_CLIENT_PREFIX) then "parent_agent"
      elsif id.start_with?(CHILD_CLIENT_PREFIX) then DELEGATE_REPORT
      elsif id == PLUGIN_CLIENT then "plugin_send"
      end
    end

    # The header for a steer or merged input message, else nil. No source
    # (or "") is the user's; an input with an unknown source too; a steer
    # with an unknown source is a plugin's (its bundle or hook label).
    def header(message)
      kind = (message[:kind] || message["kind"]).to_s
      return unless [KIND, INPUT_KIND].include?(kind)

      source = (message[:source] || message["source"]).to_s
      return HEADERS[source] if HEADERS.key?(source)

      source = "user" if source.empty?
      sender = SENDERS[source] || (kind == KIND ? "from the #{source} plugin" : SENDERS["user"])
      "[Steer #{sender}, #{HEADER_TAIL}"
    end

    # The text a steer or merged input goes out as: its header, a newline,
    # then +text+ (the message's content by default). Other messages: +text+.
    def wire_text(message, text = (message[:content] || message["content"]).to_s)
      header = header(message)
      header ? "#{header}\n#{text}" : text
    end

    def message(text:, source:)
      { role: "user", kind: KIND, source: source.to_s, content: text.to_s }
    end

    def steer?(message)
      (message[:kind] || message["kind"]).to_s == KIND
    end

    # The sources of a steer a person sent (a continue card's text, from the
    # user or a parent agent's chi answer), not a plugin's prod.
    PERSON_SOURCES = %w[user parent_agent].freeze

    # The senders whose message may cut a generation that has only been
    # thinking (Engine#cut_for_steer): the user (no source), chi send, a
    # parent agent. A plugin's never does.
    CUT_SOURCES = ["", "user", "chi_send", "parent_agent"].freeze

    def cuts?(source)
      CUT_SOURCES.include?(source.to_s)
    end

    # A steer a person sent: what a recap and a side question keep.
    def person?(message)
      steer?(message) && PERSON_SOURCES.include?((message[:source] || message["source"]).to_s)
    end

    # A user message that is a prompt or the user's steering, not a steer:
    # what "the last prompt" and "user turns" count.
    def prompt?(message)
      message.is_a?(Hash) && (message[:role] || message["role"]).to_s == "user" && !steer?(message)
    end

    # The user's lines merged into a running turn (Merge#messages).
    def input?(message)
      message.is_a?(Hash) && (message[:kind] || message["kind"]).to_s == INPUT_KIND
    end

    # A prompt that started a turn: not a steer, not input merged into a
    # running turn, except the input a turn with no prompt starts with (a
    # wake turn's delegate report, marked turn_start). What the turns a
    # page shows count.
    def turn_prompt?(message)
      prompt?(message) && (!input?(message) || (message[:turn_start] || message["turn_start"]) == true)
    end

    # Call a loop's drain: +at_answer+ goes only to a drain that takes it
    # (the Engine's); a caller's own drain (a queue's #drain) is called bare.
    # A failing drain drains nothing (the loop keeps going).
    def drain(pending_input, at_answer:)
      takes = pending_input.respond_to?(:parameters) &&
              pending_input.parameters.any? { |type, name| %i[key keyreq].include?(type) && name == :at_answer }
      takes ? pending_input.call(at_answer: at_answer) : pending_input.call
    rescue StandardError
      nil
    end

    # One injection at an iteration boundary: drain +pending_input+ and, when
    # anything was waiting, append the merge on the conversation tail (head
    # mutation would invalidate the server's prefix KV cache) and emit
    # :pending_input_merged. After a cancel the input stays queued: it runs
    # as the next turn instead of dying with this one. +answer+ (a String,
    # or a Proc called only on a merge) is the answer the merge follows, for
    # the TUI's line (the web has it as the step's streamed text); given, the drain is told it is the after-answer site (plugin
    # steers are dropped there). A blank answer is none.
    # @return [Boolean] whether anything was injected
    def inject!(conversation, pending_input, iteration:, emit:, cancel_controller:, answer: nil)
      return false unless pending_input
      return false if cancel_controller&.cancelled?

      merge = merge(drain(pending_input, at_answer: !answer.nil?))
      return false if merge.empty?

      answer = (answer.respond_to?(:call) ? answer.call : answer).to_s
      conversation.concat(merge.messages)
      emit.call({ type: :pending_input_merged, iteration: iteration, **merge.event_fields,
                  answer: answer.strip.empty? ? nil : answer })
      true
    end

    # @return [Merge]
    def merge(items)
      items = Array(items)
      lines = items.grep_v(Hash)
      steers = items.grep(Hash).filter_map do |item|
        text = (item[:text] || item["text"]).to_s.strip
        { source: (item[:source] || item["source"]).to_s, text: text } unless text.empty?
      end
      inputs = input_groups(lines)
      content = inputs.map { |input| input[:content] }.join("\n\n")
      Merge.new(content: content.empty? ? nil : content, count: content.empty? ? 0 : lines.length,
                inputs: inputs, steers: steers)
    end

    # Non-blank input lines as [{content:, source:}], one per run of lines
    # from the same sender.
    def input_groups(lines)
      pairs = lines.filter_map do |line|
        text = (line.is_a?(Line) ? line.text : line).to_s.strip
        [text, line.is_a?(Line) ? line.source : nil, line.is_a?(Line) ? line.mark : nil] unless text.empty?
      end
      pairs.chunk_while { |a, b| a[1] == b[1] }.map do |run|
        { content: run.map(&:first).join("\n\n"), source: run.first[1], mark: run.first[2] }.compact
      end
    end
  end
end
