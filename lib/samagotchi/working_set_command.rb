# frozen_string_literal: true

require_relative "working_set"
require_relative "working_set_steer"

module Samagotchi
  # /working-set: with no arguments the session's working set (WorkingSet,
  # as the web's list shows it: each item, what was done to it, its state
  # and tokens, then the changes the next turn starts with); `drop KEY…`
  # and `undrop KEY…` steer it (WorkingSetSteer). KEY: a path (absolute or
  # the session's folder's), memory:NAME, a URL.
  #
  # An op runs between turns (mid_turn :queue: a line sent while a turn
  # runs waits for its end), on a copy of the session's messages that
  # replaces them, so the next turn's first request is the first with it.
  class WorkingSetCommand
    NAME = "/working-set"
    USAGE = "usage: #{NAME} [drop KEY… | undrop KEY…] (KEY: a path, memory:NAME or a URL)".freeze
    VERBS = [WorkingSetSteer::DROP, WorkingSetSteer::UNDROP].freeze
    OP_WORDS = { WorkingSetSteer::DROP => "dropped", WorkingSetSteer::UNDROP => "undropped" }.freeze

    # @param engine [Engine] #session, #working_set_strategy,
    #   #clone_messages, #replace_messages
    # @param save [#call] saves the session after a change
    def initialize(engine:, save:)
      @engine = engine
      @save = save
    end

    # @param args [String] what follows /working-set
    # @return [Array(String, Boolean, Symbol)] the reply, whether the
    #   conversation changed, and :ok or :error (every key refused)
    # @raise [ArgumentError] a line that isn't one (its message and USAGE)
    def run(args)
      verb, *words = args.to_s.split
      return [listing, false, :ok] if verb.nil?
      raise ArgumentError, USAGE unless VERBS.include?(verb) && !words.empty?

      session = @engine.session or raise ArgumentError, "no session yet"
      cwd = session.working_directory
      strategy = @engine.working_set_strategy
      messages = @engine.clone_messages(session.messages)
      lines = []
      done = 0
      words.each do |word|
        target = WorkingSetSteer.target(word, cwd: cwd)
        result = if verb == WorkingSetSteer::DROP
                   WorkingSetSteer.drop(messages, target, strategy: strategy, cwd: cwd)
                 else
                   sent = !WorkingSetSteer.pending?(messages, WorkingSetSteer::DROP, target)
                   WorkingSetSteer.undrop(messages, target, strategy: strategy, cwd: cwd, sent: sent)
                 end
        messages = WorkingSetSteer.record!(messages, result)
        lines << done_line(result)
        done += 1
      rescue WorkingSetSteer::Refused => e
        lines << "#{verb} #{word}: #{e.message}"
      end
      if done.positive?
        @engine.replace_messages(messages)
        @save.call(session)
      end
      [lines.join("\n"), done.positive?, done.positive? ? :ok : :error]
    end

    # The set under the strategy the next turn runs, and the pending ops.
    def listing
      session = @engine.session
      return "no session yet" unless session

      messages = Array(session.messages)
      items = WorkingSet.build(messages, cwd: session.working_directory, strategy: @engine.working_set_strategy).items
      return "working set: empty (the files, memories and URLs the turns read show here)\n#{USAGE}" if items.empty?

      rows = items.map { |item| [name(item, session.working_directory), words(item)] }
      width = rows.map { |row, _| row.length }.max
      lines = ["working set (#{items.size} item#{"s" unless items.size == 1}):"]
      lines.concat(rows.map { |row, text| "  #{row.ljust(width)}  #{text}" })
      pending = WorkingSetSteer.pending_ops(messages)
      unless pending.empty?
        lines << "at the next turn's start: #{pending.map { |op| "#{OP_WORDS[op["op"]]} #{op["label"]}" }.join(", ")}"
      end
      lines << USAGE
      lines.join("\n")
    end

    private

    def name(item, cwd)
      case item.kind
      when WorkingSet::FILE then WorkingSetSteer.target(item.key, cwd: cwd).label
      when WorkingSet::MEMORY then "#{WorkingSetSteer::MEMORY_PREFIX}#{item.key}"
      else item.key
      end
    end

    def words(item)
      parts = [item.ops.join(", ")]
      parts << "×#{item.count}" if item.count > 1
      parts << item.state unless item.state == WorkingSet::LIVE
      parts << "~#{item.tokens} tokens" if item.tokens.positive?
      parts.join(" · ")
    end

    def done_line(done)
      what = "#{OP_WORDS[done.op]} #{done.target.label} (#{done.ids.join(", ")})"
      if done.op == WorkingSetSteer::DROP
        frees = done.freed_chars.positive? ? "frees #{WorkingSetSteer.k(done.freed_chars)}" : "frees nothing, the stubs are as long"
        "#{what}: the next turn's first request sends the stubs (#{frees}; the server reads the " \
          "#{WorkingSetSteer.k(done.tail_chars)} after them again)"
      elsif done.free
        "#{what}: its drop was never sent; nothing changes"
      else
        "#{what}: the next request sends it whole again (the server reads the #{WorkingSetSteer.k(done.tail_chars)} " \
          "from it on again)"
      end
    end
  end
end
