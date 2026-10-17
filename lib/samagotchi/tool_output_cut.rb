# frozen_string_literal: true

require_relative "tool_output_files"

module Samagotchi
  # How ToolRunner cuts a tool's output that is longer than
  # max_tool_output_chars, by the tool's policy (POLICIES, by its built-in
  # name; any other tool gets :head).
  #
  # :head keeps the first chars and ends with head_line ("[cut: N of M
  # chars; read it in parts]"): read (which has line ranges) and every tool
  # with no policy of its own.
  #
  # :head_tail_file (execute) keeps a short head and a long tail, whole
  # lines, with one gap line between them, and saves the whole output
  # (ToolOutputFiles, through the caller's +save+): a test run's verdict and
  # an error are at the end. The gap line names the saved file and the lines
  # left out of it, so the model reads or rg's it instead of running the
  # command again. execute's stdout and stderr are cut each on its own
  # (stdout gets about two thirds of the room), its exit line always kept.
  # The cut text still fits the cap, and comes from the content alone (no
  # clock): the same output gives the same text.
  #
  # :head_tail_ref (task_wait, delegate, delegate_result) cuts the same
  # way, as one block, and saves nothing: the whole is already in a file (a
  # task's log, the child's reply in its output/ folder), which the tool
  # gave with its text (Tools::RefText) and the gap line names.
  module ToolOutputCut
    POLICIES = { "execute" => :head_tail_file, "task_wait" => :head_tail_ref, "delegate" => :head_tail_ref,
                 "delegate_result" => :head_tail_ref }.freeze

    # What a :head_tail_ref tool's file holds, for its gap line.
    REF_WHAT = { "task_wait" => "the task's whole output", "delegate" => "the child's whole reply",
                 "delegate_result" => "the child's whole reply" }.freeze

    # A head cut's last line (head_line), as LLMContextStale recognizes a
    # partial read by it. Kept in sync with head_line by its spec.
    HEAD_CUT = /\[cut: \d+ of \d+ chars; read it in parts\]\z/

    # What a web row keeps of a tool's output, on a reload
    # (MessageParts) and a mid-turn join (Bridge::TurnAccumulator): the
    # row shows 300 chars and the rest on hover. A longer one keeps its head
    # and tail (preview).
    WEB_PREVIEW_CHARS = 2000

    # The head's chars at most (execute.cut_head_chars): never more than a
    # quarter of the room; the tail gets the rest.
    HEAD_CHARS = 1000
    # A tail shorter than this isn't worth it: the cap is too small, and
    # the output gets the head cut.
    MIN_TAIL = 200

    # An execute that didn't finish: stopped, killed at the limit or
    # handed over (its result starts with an "Error:" or a "Still running"
    # line after the lead), or with no exit line last.
    UNFINISHED = /\A(?:ran as: [^\n]*\n)?\[execute\]\n(?:Error: |Still running at the )/

    # The marks of a text that is already a head-and-tail preview (execute's
    # own above execute.truncate_at_bytes): its saved copy isn't the whole
    # output.
    PREVIEW_MARK = "[TRUNCATED_PREVIEW_HEAD]"
    # execute's blocks (Tools::Execute#call): stdout, stderr, then the exit
    # line last (a hint in brackets may follow it). A killed or handed-over
    # command has none: its output isn't all there is. A command a signal
    # ended (a segfault, an OOM kill) has an exit line with no number
    # ("exit: "): it ended, so its output is all there is. The JS twin is
    # turn_html.js's EXIT_LINE; spec/fixtures/exit_lines.json holds the
    # cases both must answer alike (both specs run it).
    STDOUT_LABEL = "\nstdout:\n"
    STDERR_LABEL = "\nstderr:\n"
    EXIT_LINE = /\nexit: (?:-?\d+)?[^\n]*(?:\n\([^\n]*\))?\z/

    # The share of the room stdout gets when both blocks are cut.
    STDOUT_SHARE = Rational(2, 3)

    # A cut part: [from, length] of the output.
    Block = Data.define(:from, :length) do
      def to = from + length
    end

    module_function

    # @param tool [String, nil] the call's tool name
    # @return [Symbol] its policy
    def policy(tool) = POLICIES.fetch(tool.to_s, :head)

    # +output+ cut to +cap+ chars by +tool+'s policy.
    # @param save [#call, nil] (text, dry:) → ToolOutputFiles::Saved, or a
    #   String saying why it wasn't saved ("no session", "Errno::ENOSPC");
    #   dry: true only says where it would go. It writes only once the
    #   head-and-tail cut is known to fit the cap with that file's gap
    #   line: a cut that falls back to the head cut saves nothing.
    # @param head_chars [Integer] execute.cut_head_chars
    # @return [Array(String, Object)] the text the model gets, and what
    #   +save+ returned (nil when it wasn't called)
    # @param ref [String, nil] :head_tail_ref: the file the whole text is in
    # @param ref_stderr [String, nil] :head_tail_ref: its stderr's file, if apart
    def apply(output, cap:, tool:, save: nil, ref: nil, ref_stderr: nil, head_chars: HEAD_CHARS)
      kind = policy(tool)
      return [head(output, cap), nil] if kind == :head || cap < MIN_TAIL * 3

      if kind == :head_tail_ref
        text = head_tail(output, cap: cap, blocks: [Block.new(from: 0, length: output.length)], head_chars: head_chars,
                                 gap: RefGap.new(output, ref, REF_WHAT.fetch(tool.to_s, "the whole output"),
                                                 stderr: ref_stderr))
        return [text || head(output, cap), nil]
      end

      blocks = execute_blocks(output)
      planned = save ? save.call(output, dry: true) : "no session"
      text = head_tail(output, cap: cap, blocks: blocks, head_chars: head_chars, gap: FileGap.new(output, planned))
      return [head(output, cap), nil] unless text
      return [text, planned] unless planned.is_a?(ToolOutputFiles::Saved)

      saved = save.call(output)
      return [text, saved] if saved.is_a?(ToolOutputFiles::Saved)

      # The write failed: the line says so instead, if that still fits.
      text = head_tail(output, cap: cap, blocks: blocks, head_chars: head_chars, gap: FileGap.new(output, saved))
      [text || head(output, cap), text ? saved : nil]
    end

    def unfinished?(output) = output.match?(UNFINISHED) || !output.match?(EXIT_LINE)

    # +output+ as a web row keeps it, at most +cap+ chars (a reload's
    # MessageParts, the Bridge's snapshot): a read's head (its view numbers
    # the lines from the first), any other tool's head and tail with a gap
    # line, as the model's cut keeps a test run's verdict and exit line.
    def preview(output, cap:, tool:)
      return output if output.length <= cap
      return output[0, cap] if tool.to_s == "read"

      head_tail(output, cap: cap, blocks: [Block.new(from: 0, length: output.length)], head_chars: HEAD_CHARS,
                                  gap: RefGap.new(output, nil, nil)) || output[0, cap]
    end

    # +output+ cut to +cap+ chars, the cut line included: the model knows
    # what it didn't get. A cap smaller than the line keeps +cap+ chars and
    # the line goes past it.
    def head(output, cap)
      keep = cap - head_line(cap, output.length).length
      keep = cap unless keep.positive?
      "#{output[0, keep]}#{head_line(keep, output.length)}"
    end

    def head_line(kept, total)
      "\n[cut: #{kept} of #{total} chars; read it in parts]"
    end

    # +output+ with each of +blocks+ that doesn't fit its share of the room
    # cut to its head and tail, a gap line between them (the first cut's
    # line +gap+.line, the next ones' +gap+.short). nil when the cap leaves
    # too little room.
    def head_tail(output, cap:, blocks:, head_chars:, gap:)
      fixed = output.length - blocks.sum(&:length)
      # Room for the gap lines (their longest numbers) and a newline each.
      room = cap - fixed - (gap.line_max.length + 2) - (blocks.size > 1 ? gap.short_max.length + 2 : 0)
      shares = shares(blocks.map(&:length), room)
      return nil unless shares

      text = +""
      at = 0
      first = true
      blocks.zip(shares).each do |block, share|
        text << output[at...block.from]
        at = block.to
        body = output[block.from, block.length]
        if body.length <= share
          text << body
          next
        end

        shown = cut_block(body, share, head_chars)
        return nil unless shown

        head_part, tail_part = shown
        left_out = Block.new(from: block.from + head_part.length, length: body.length - head_part.length - tail_part.length)
        text << head_part
        text << "\n" unless head_part.end_with?("\n") || head_part.empty?
        text << (first ? gap.line(left_out) : gap.short(left_out)) << "\n" << tail_part
        first = false
      end
      text << output[at..]
      text.length <= cap ? text : nil
    end

    # The room each block gets: stdout STDOUT_SHARE when both need cutting,
    # a block that needs less gives the rest to the other. nil when there
    # isn't room for a useful tail.
    def shares(lengths, room)
      return nil if room < MIN_TAIL
      return [room] if lengths.size == 1

      first = (room * STDOUT_SHARE).floor
      second = room - first
      if lengths[1] < second
        [room - lengths[1], lengths[1]]
      elsif lengths[0] < first
        [lengths[0], room - lengths[0]]
      else
        [first, second]
      end
    end

    # +body+'s head and tail within +share+ chars, each snapped to whole
    # lines when that keeps at least half of it. nil when the tail would
    # be shorter than MIN_TAIL.
    def cut_block(body, share, head_chars)
      head_size = [head_chars, share / 4].min
      tail_size = share - head_size
      return nil if tail_size < MIN_TAIL

      head_part = body[0, head_size]
      newline = head_part.rindex("\n")
      head_part = head_part[0, newline + 1] if newline && newline + 1 >= head_size / 2
      tail_part = body[-tail_size..]
      newline = tail_part.index("\n")
      tail_part = tail_part[(newline + 1)..] if newline && tail_part.length - newline - 1 >= tail_size / 2
      [head_part, tail_part]
    end

    # execute's stdout and stderr bodies, each cut on its own; any other
    # text (no "stdout:"/"stderr:" block: an error, a hand-over) is one.
    def execute_blocks(output)
      ends = output.match(EXIT_LINE)&.begin(0) || output.length
      stdout_at = output.index(STDOUT_LABEL)
      stderr_at = output.rindex(STDERR_LABEL, ends - STDERR_LABEL.length)
      stderr_at = nil if stderr_at && stdout_at && stderr_at < stdout_at
      blocks = []
      if stdout_at
        from = stdout_at + STDOUT_LABEL.length
        blocks << Block.new(from: from, length: [(stderr_at || ends) - from, 0].max)
      end
      blocks << Block.new(from: stderr_at + STDERR_LABEL.length, length: ends - stderr_at - STDERR_LABEL.length) if stderr_at
      blocks.empty? ? [Block.new(from: 0, length: output.length)] : blocks
    end

    # The gap line of a :head_tail_ref cut: the file the whole text is in.
    class RefGap
      def initialize(output, ref, what, stderr: nil)
        @output = output
        @ref = ref.to_s
        @what = what
        @stderr = stderr.to_s
      end

      def line(left_out)
        also = @stderr.empty? ? "" : " (its stderr in #{@stderr})"
        where = @ref.empty? ? "" : "; #{@what} is in #{@ref}#{also}: read it with start_line/end_line or rg it"
        "[cut: #{left_out.length} of #{@output.length} chars not shown#{where}]"
      end

      def short(left_out) = "[cut: #{left_out.length} chars not shown]"
      def line_max = line(Block.new(from: 0, length: @output.length))
      def short_max = short(Block.new(from: 0, length: @output.length))
    end

    # The gap lines of a :head_tail_file cut: where the whole output is
    # saved, and which of its lines the cut left out.
    class FileGap
      # @param saved [ToolOutputFiles::Saved, String] the saved file, or
      #   why there is none
      def initialize(output, saved)
        @output = output
        @saved = saved.is_a?(String) ? nil : saved
        @reason = saved.is_a?(String) ? saved : nil
      end

      # The first cut's line.
      def line(left_out)
        return "[cut: #{left_out.length} of #{@output.length} chars not shown; #{unsaved_note}]" unless @saved

        "[cut: #{lines_text(left_out)} of the saved file not shown (#{left_out.length} of #{@output.length} chars); " \
          "#{saved_note}]"
      end

      # A further cut's line, the file named by the first.
      def short(left_out)
        return "[cut: #{left_out.length} chars not shown]" unless @saved

        "[cut: #{lines_text(left_out)} of the saved file not shown (#{left_out.length} chars)]"
      end

      # The longest line and short line it can write (budgeting).
      def line_max = line(widest)
      def short_max = short(widest)

      private

      def widest = Block.new(from: 0, length: @output.length)

      def lines_text(left_out)
        return "lines #{lines_total}-#{lines_total}" if left_out.from.zero? && left_out.length == @output.length

        first = @output[0, left_out.from].count("\n") + 1
        last = @output[0, left_out.to].count("\n")
        last += 1 unless left_out.to.zero? || @output[left_out.to - 1] == "\n"
        "lines #{first}-#{[last, first].max}"
      end

      def lines_total = @saved.lines

      def where = "#{@saved.path} (#{@saved.bytes} bytes, #{@saved.lines} lines)"

      def saved_note
        if @output.include?(PREVIEW_MARK)
          "this preview is saved in #{where}; the full output wasn't kept: read the preview with " \
            "start_line/end_line or rg it"
        elsif ToolOutputCut.unfinished?(@output)
          "the output it printed is saved in #{where}: read it with start_line/end_line or rg it"
        else
          "the whole output is saved in #{where}: read it with start_line/end_line or rg it; don't rerun the command"
        end
      end

      def unsaved_note
        "the whole output wasn't saved (#{@reason}); to look past this, rerun with the output sent to a file " \
          "(cmd > /tmp/out.txt 2>&1) and read that"
      end
    end
  end
end
