# frozen_string_literal: true

require_relative "working_set"
require_relative "working_set_steer"

module Samagotchi
  # /working-set: with no arguments the session's working set (WorkingSet,
  # as the web's list shows it: each item, what was done to it, its state
  # and tokens, then the changes the next turn starts with); `drop KEY…`,
  # `undrop KEY…`, `pin KEY…` and `unpin KEY…` steer it (WorkingSetSteer).
  # KEY: a path (absolute or the session's folder's), memory:NAME, a URL;
  # one with spaces quoted ("my dir/a.rb", WorkingSetSteer.words), as the
  # listing shows it.
  # A pin is saved on the session (Session#working_set_pins); the turn-start
  # note names it only where the model has forget_outputs (the strategy's
  # forget layer), or to cancel a pin or an unpin it named.
  #
  # An op runs between turns (mid_turn :queue: a line sent while a turn
  # runs waits for its end), on a copy of the session's messages that
  # replaces them, so the next turn's first request is the first with it.
  class WorkingSetCommand
    NAME = "/working-set"
    USAGE = "usage: #{NAME} [drop KEY… | undrop KEY… | pin KEY… | unpin KEY…] (KEY: a path, memory:NAME or a URL; \"quote\" one with spaces)".freeze
    VERBS = [WorkingSetSteer::DROP, WorkingSetSteer::UNDROP, WorkingSetSteer::PIN, WorkingSetSteer::UNPIN].freeze
    OP_WORDS = { WorkingSetSteer::DROP => "dropped", WorkingSetSteer::UNDROP => "undropped",
                 WorkingSetSteer::PIN => "pinned", WorkingSetSteer::UNPIN => "unpinned" }.freeze
    PIN_OPS = [WorkingSetSteer::PIN, WorkingSetSteer::UNPIN].freeze

    # @param engine [Engine] #session, #working_set_strategy,
    #   #clone_messages, #replace_messages
    # @param save [#call] saves the session after a change
    def initialize(engine:, save:)
      @engine = engine
      @save = save
    end

    # @param args [String] what follows /working-set
    # @return [Array(String, Array<Symbol>, Symbol)] the reply, what
    #   changed (:messages, :working_set_pins; none when nothing did), and
    #   :ok or :error (every key refused)
    # @raise [ArgumentError] a line that isn't one (its message and USAGE)
    def run(args)
      verb, *words = WorkingSetSteer.words(args)
      return [listing, [], :ok] if verb.nil?
      raise ArgumentError, USAGE unless VERBS.include?(verb) && !words.empty?

      session = @engine.session or raise ArgumentError, "no session yet"
      cwd = session.working_directory
      strategy = @engine.working_set_strategy
      messages = @engine.clone_messages(session.messages)
      pins = session.working_set_pins
      lines = []
      done = 0
      noted = false
      words.each do |word|
        target = WorkingSetSteer.target(word, cwd: cwd)
        result = op(verb, messages, pins, target, strategy, cwd)
        [result.undone, result].compact.select { |each| noted?(each, messages, strategy) }.each do |each|
          messages = WorkingSetSteer.record!(messages, each)
          noted = true
        end
        pins = WorkingSetSteer.pinning(pins, result) if PIN_OPS.include?(result.op)
        lines << done_line(result.undone) if result.undone
        lines << done_line(result, strategy)
        done += 1
      rescue WorkingSetSteer::Refused => e
        lines << "#{verb} #{WorkingSetSteer.quote(word)}: #{e.message}"
      end
      changed = done.positive? ? save(session, noted && messages, pins) : []
      [lines.join("\n"), changed, done.positive? ? :ok : :error]
    end

    # The set under the strategy the next turn runs, and the pending ops.
    def listing
      session = @engine.session
      return "no session yet" unless session

      messages = Array(session.messages)
      items = WorkingSet.build(messages, cwd: session.working_directory, strategy: @engine.working_set_strategy,
                               pins: session.working_set_pins).items
      return "working set: empty (the files, memories and URLs the turns read show here)\n#{USAGE}" if items.empty?

      rows = items.map { |item| [WorkingSetSteer.quote(name(item, session.working_directory)), words(item)] }
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

    def op(verb, messages, pins, target, strategy, cwd)
      case verb
      when WorkingSetSteer::DROP then WorkingSetSteer.drop(messages, target, strategy: strategy, cwd: cwd, pins: pins)
      when WorkingSetSteer::UNDROP
        sent = !WorkingSetSteer.pending?(messages, WorkingSetSteer::DROP, target)
        WorkingSetSteer.undrop(messages, target, strategy: strategy, cwd: cwd, sent: sent)
      when WorkingSetSteer::PIN then WorkingSetSteer.pin(messages, pins, target, strategy: strategy, cwd: cwd)
      else WorkingSetSteer.unpin(pins, target)
      end
    end

    # Whether the turn-start note lists +done+: a drop or an undrop always;
    # a pin or an unpin where the model has forget_outputs, or when it
    # cancels one the note lists.
    def noted?(done, messages, strategy)
      return true unless PIN_OPS.include?(done.op)

      forget?(strategy) || WorkingSetSteer.pending?(messages, WorkingSetSteer::INVERSE.fetch(done.op), done.target)
    end

    def forget?(strategy) = Array(strategy).include?(:forget)

    # Puts the ops' messages (nil: unchanged) and pins in place and saves
    # the session.
    # @return [Array<Symbol>] what changed
    def save(session, messages, pins)
      changed = []
      if messages
        @engine.replace_messages(messages)
        changed << :messages
      end
      unless pins == session.working_set_pins
        session.working_set_pins = pins
        changed << :working_set_pins
      end
      @save.call(session) unless changed.empty?
      changed
    end

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
      parts << "pinned" if item.pinned
      parts << "~#{item.tokens} tokens" if item.tokens.positive?
      parts.join(" · ")
    end

    def done_line(done, strategy = nil)
      ids = done.ids.empty? ? "" : " (#{done.ids.join(", ")})"
      "#{op_line(done, "#{OP_WORDS[done.op]} #{done.target.label}#{ids}", strategy)}#{with_line(done)}"
    end

    # A memory_read of several names is one output: the op acted on the
    # others' read too. Says which names went with it.
    def with_line(done)
      return "" if done.shared_with.empty?

      names = done.shared_with.map { |name| "memory #{name}" }.join(", ")
      "; the same memory_read holds #{names}: #{OP_WORDS[done.op]} with it (that read only)"
    end

    def op_line(done, what, strategy)
      case done.op
      when WorkingSetSteer::PIN
        off = forget?(strategy) ? "" : " (the strategy has no forget layer now: the pin holds when it has)"
        "#{what}: forget_outputs refuses its outputs, its later reads too#{off}"
      when WorkingSetSteer::UNPIN then "#{what}: the model may forget it again"
      when WorkingSetSteer::DROP
        frees = done.freed_chars.positive? ? "frees #{WorkingSetSteer.k(done.freed_chars)}" : "frees nothing, the stubs are as long"
        "#{what}: the next turn's first request sends the stubs (#{frees}; the server reads the " \
          "#{WorkingSetSteer.k(done.tail_chars)} after them again)"
      else
        undrop_line(what, done)
      end
    end

    def undrop_line(what, done)
      if done.free
        "#{what}: its drop was never sent; nothing changes"
      else
        "#{what}: the next request sends it whole again (the server reads the #{WorkingSetSteer.k(done.tail_chars)} " \
          "from it on again)"
      end
    end
  end
end
